<#
.SYNOPSIS
    验收自检：hosts 记录、根证书、6 个站点状态码与证书链。

.DESCRIPTION
    只读，不改任何东西。三项全过才算通过，退出码 0；否则 1。

    ★ 证书链刻意用默认校验，不用 X509Chain.Build()。后者只拿叶子证书，
      不会用服务端送来的中间证书，对 Caddy 这种「根 + 中间」的结构会给出
      假阴性（PartialChain）。实现上用 SslStream + 默认校验回调，理由见 Get-TlsInfo。

.NOTES
    期望状态码不是「全部 200」：jenkins / ldapadmin / auth 是受保护站点，
    未登录时 302 到 oauth2 才是对的；返回 200 反而是漏了认证。
    ★ dex 例外：它的根路径 `/` 本来就是 404（dex 没有根 handler），
      判据打的是 `/dex/healthz` = 200。2026-11-01 真机实测。
#>
[CmdletBinding()]
param(
    [string]$Domain = 'org-devops.com',
    [string]$GatewayIp = '10.22.67.213'
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# 子域 -> 允许的状态码。302 = 未登录跳 oauth2，是正确的；200 = 公开站点。
$Expectations = [ordered]@{
    'jenkins'   = @(302)
    'nexus'     = @(200)
    'ldapadmin' = @(302)
    'dex'       = @(200)
    'auth'      = @(302)
    'home'      = @(200)
}

# 子域 -> 探测路径（缺省是 /）
$ProbePaths = @{ 'dex' = '/dex/healthz' }

$HostsPath = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
$failures = New-Object System.Collections.Generic.List[string]

function Test-HostsEntry {
    param([string]$Sub)

    if (-not (Test-Path -LiteralPath $HostsPath)) {
        $failures.Add("找不到 hosts 文件：$HostsPath")
        return $false
    }
    # 注释行不算；按「IP + 域名」精确匹配，避免把别的 IP 当成通过
    $pattern = "^\s*$([regex]::Escape($GatewayIp))\s+$([regex]::Escape("$Sub.$Domain"))\s*$"
    $hit = Select-String -LiteralPath $HostsPath -Pattern $pattern -Quiet
    if (-not $hit) {
        $failures.Add("hosts 缺少：$GatewayIp`t$Sub.$Domain")
    }
    return $hit
}

function Test-RootCa {
    # 只看「有没有 Caddy 内部 CA 的根证书」，不按指纹硬编码：
    # down -v 重建 CA 后指纹会变，硬编码就等于每次都要改脚本。
    $roots = Get-ChildItem Cert:\LocalMachine\Root |
        Where-Object { $_.Subject -like '*Caddy Local Authority*' }
    if (-not $roots) {
        $failures.Add('「受信任的根证书颁发机构」里没有 Caddy Local Authority 根证书')
        return $false
    }
    Write-Host ("  根证书：{0}" -f $roots[0].Subject) -ForegroundColor DarkGray
    Write-Host ("  指纹  ：{0}" -f $roots[0].Thumbprint) -ForegroundColor DarkGray
    return $true
}

function Get-TlsInfo {
    <#
        ★ 为什么不用 HttpClient 的自定义校验回调（2026-11-01 实测）：
          PS 5.1 里把 ScriptBlock 赋给 ServerCertificateCustomValidationCallback 后，
          回调在**线程池线程**上执行，会抛
          「此线程中没有可用于运行脚本的运行空间」——脚本直接崩，而这条报错
          完全指不到证书上。SslStream 的校验回调是在 AuthenticateAsClient 里
          **同步、同线程**调用的，ScriptBlock 委托可以正常工作。
    #>
    param([string]$HostName)

    $script:certOk = $false
    $script:certErr = ''
    $script:certSubject = ''
    $script:certIssuer = ''

    $tcp = $null
    $ssl = $null
    try {
        $tcp = New-Object System.Net.Sockets.TcpClient
        $tcp.Connect($HostName, 443)
        $ssl = New-Object System.Net.Security.SslStream($tcp.GetStream(), $false, {
            param($sender, $cert, $chain, $errors)
            $script:certOk = ($errors -eq [System.Net.Security.SslPolicyErrors]::None)
            $script:certErr = "$errors"
            if ($cert) {
                $script:certSubject = $cert.Subject
                $script:certIssuer = $cert.Issuer
            }
            # 一律放行，由调用方按 $certOk 判定；否则拿不到证书信息
            return $true
        })
        $ssl.AuthenticateAsClient($HostName)
    } catch {
        $script:certErr = "握手失败：$($_.Exception.GetBaseException().Message)"
    } finally {
        if ($ssl) { $ssl.Dispose() }
        if ($tcp) { $tcp.Close() }
    }
    return @{
        Ok      = $script:certOk
        Error   = $script:certErr
        Subject = $script:certSubject
        Issuer  = $script:certIssuer
    }
}

function Test-Site {
    param([string]$Sub, [int[]]$Expect)

    $hostName = "$Sub.$Domain"
    $path = if ($ProbePaths.ContainsKey($Sub)) { $ProbePaths[$Sub] } else { '/' }
    $url = "https://$hostName$path"
    $tls = Get-TlsInfo -HostName $hostName

    # 状态码用 HttpWebRequest：.NET Framework 自带，不需要 Add-Type 加载
    # System.Net.Http（PS 5.1 里那个类型默认不在，加载时机还很脆）。
    # AllowAutoRedirect=$false 时 302 不抛异常，直接返回响应。
    $code = -1
    $req = $null
    try {
        $req = [System.Net.HttpWebRequest]::Create($url)
        $req.AllowAutoRedirect = $false
        $req.Timeout = 20000
        $req.ReadWriteTimeout = 20000
        $req.UserAgent = 'orgflow-acceptance'
        $resp = $req.GetResponse()
        $code = [int]$resp.StatusCode
        $resp.Close()
    } catch [System.Net.WebException] {
        $web = $_.Exception
        if ($web.Response) {
            # 4xx/5xx 也走这里，但状态码依然是有效判据
            $code = [int]$web.Response.StatusCode
            $web.Response.Close()
        } elseif (-not $tls.Ok) {
            $failures.Add("$Sub`: 证书校验失败（$($tls.Error)）——根证书没导入？")
        } else {
            $failures.Add("$Sub`: 请求失败 —— $($web.GetBaseException().Message)")
        }
    } finally {
        if ($req) { $req.Abort() }
    }

    $ok = $false
    if ($code -ge 0) {
        if ($Expect -contains $code) {
            $ok = $true
        } else {
            $failures.Add("$Sub`: 状态码 $code，期望 $($Expect -join '/')")
        }
    }

    $flag = if ($ok) { 'OK  ' } else { 'FAIL' }
    $colour = if ($ok) { 'Green' } else { 'Red' }
    Write-Host ("  [{0}] {1,-10} {2,4}  期望 {3,-6} {4}" -f
        $flag, $Sub, $code, ($Expect -join '/'), $tls.Issuer) -ForegroundColor $colour
    return $ok
}

Write-Host '== 1. hosts ==' -ForegroundColor Cyan
foreach ($sub in $Expectations.Keys) {
    [void](Test-HostsEntry -Sub $sub)
}
if ($failures.Count -eq 0) { Write-Host '  6 条记录齐全' -ForegroundColor Green }

Write-Host '== 2. 根证书 ==' -ForegroundColor Cyan
[void](Test-RootCa)

Write-Host '== 3. 站点（状态码 + 证书链）==' -ForegroundColor Cyan
foreach ($sub in $Expectations.Keys) {
    [void](Test-Site -Sub $sub -Expect $Expectations[$sub])
}

Write-Host ''
if ($failures.Count -gt 0) {
    Write-Host "验收未通过，$($failures.Count) 项问题：" -ForegroundColor Red
    $failures | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    exit 1
}

Write-Host '验收全部通过。' -ForegroundColor Green
exit 0
