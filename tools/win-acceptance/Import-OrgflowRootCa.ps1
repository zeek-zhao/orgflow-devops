<#
.SYNOPSIS
    从网关机器拉 Caddy 内部 CA 的根证书，导入「受信任的根证书颁发机构」。

.DESCRIPTION
    ★ 证书运行时拉，不提交进仓库。
      因为 `docker compose down -v` 会重建 CA，提交进仓库的 .crt 会立刻作废，
      而症状是「浏览器又开始报警」，很难联想到是 CA 换了。

    拉取方式：ssh 到网关机，确保 out/ca/root.crt 已导出，然后 cat 回来。
    没有 ssh / 没有 key 时，可以先用 -CaFile 指定一份手工拷来的证书。

.NOTES
    ★ 不要用 `certutil -store` 判断「是否已安装」：失败时它返回负数 HRESULT
      （例如 -2146893807），cmd 的 `if errorlevel 1` 只认非负值，会误判成成功。
      这里一律枚举 Cert:\LocalMachine\Root。
#>
[CmdletBinding()]
param(
    [string]$GatewayIp = '192.0.2.10',
    [string]$SshUser = 'jenkins',
    [string]$SshKey = "$HOME\.ssh\id_ed25519",
    [string]$RemoteRepo = '~/workbuddy/orgflow-devops',
    # 已有证书文件时直接指定，跳过 ssh 拉取
    [string]$CaFile = ''
)

$ErrorActionPreference = 'Stop'

function Assert-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw '需要管理员权限（要写 LocalMachine 证书存储）：直接运行 acceptance.bat，或用管理员 PowerShell。'
    }
}

function Get-RemoteRootCa {
    param([string]$Target)

    $ssh = Get-Command ssh -ErrorAction SilentlyContinue
    if (-not $ssh) {
        throw "找不到 ssh 客户端。可以改为：把网关机上的 $RemoteRepo/out/ca/root.crt 拷到本机，再用 -CaFile 指定。"
    }

    # --export 是幂等的；已经导出过就直接 cat。注意 ssh 里不要嵌套引号，
    # 多层引号在 Windows 上必然出问题，所以整段当成一个单引号字符串传过去。
    $remote = "cd $RemoteRepo && { [ -s out/ca/root.crt ] || bash scripts/ca-install.sh --export >/dev/null 2>&1; } && cat out/ca/root.crt"
    $sshArgs = @('-n')
    if (Test-Path -LiteralPath $SshKey) {
        $sshArgs += @('-i', $SshKey, '-o', 'IdentitiesOnly=yes')
    }
    $sshArgs += @("$SshUser@$GatewayIp", $remote)

    Write-Host "从 $SshUser@$GatewayIp 拉根证书…" -ForegroundColor Cyan
    $pem = & ssh @sshArgs
    if ($LASTEXITCODE -ne 0) {
        throw "ssh 拉取失败（退出码 $LASTEXITCODE）。确认 key 可用，或改用 -CaFile 指定手工拷贝的证书。"
    }
    if (-not $pem -or ($pem -join "`n") -notmatch 'BEGIN CERTIFICATE') {
        throw '拉回来的内容不是 PEM 证书。检查网关机上 out/ca/root.crt 是否存在（先跑一次 make ca）。'
    }
    Set-Content -LiteralPath $Target -Value $pem -Encoding ASCII
}

Assert-Administrator

$temp = Join-Path $env:TEMP 'orgflow-root-ca.crt'
try {
    if ($CaFile) {
        if (-not (Test-Path -LiteralPath $CaFile)) { throw "找不到 -CaFile 指定的文件：$CaFile" }
        Copy-Item -LiteralPath $CaFile -Destination $temp -Force
    } else {
        Get-RemoteRootCa -Target $temp
    }

    $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($temp)
    $thumbprint = $cert.Thumbprint
    Write-Host ("根证书：{0}" -f $cert.Subject) -ForegroundColor Cyan
    Write-Host ("指纹    ：{0}" -f $thumbprint) -ForegroundColor Cyan

    # 枚举存储判断是否已装（不要用 certutil，见文件头说明）
    $existing = Get-ChildItem Cert:\LocalMachine\Root | Where-Object { $_.Thumbprint -eq $thumbprint }
    if ($existing) {
        Write-Host '该证书已在「受信任的根证书颁发机构」中，跳过导入。' -ForegroundColor Yellow
    } else {
        Import-Certificate -FilePath $temp -CertStoreLocation Cert:\LocalMachine\Root | Out-Null
        Write-Host '已导入「受信任的根证书颁发机构」。' -ForegroundColor Green
    }
} finally {
    Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
}
