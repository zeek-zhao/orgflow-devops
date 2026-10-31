<#
.SYNOPSIS
    验收自检：hosts 记录、根证书、6 个站点状态码与证书链。

.DESCRIPTION
    只读，不改任何东西。三项全过才算通过，退出码 0；否则 1。

    ★ 证书链刻意用默认校验（SslStream / HttpClient 的默认行为），
      不用 X509Chain.Build()。后者只拿叶子证书，不会用服务端送来的中间证书，
      对 Caddy 这种「根 + 中间」的结构会给出假阴性（PartialChain）。

.NOTES
    期望状态码不是「全部 200」：jenkins / ldapadmin / dex / auth 是受保护站点，
    未登录时 302 到 oauth2 才是对的；返回 200 反而是漏了认证。
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
    'dex'       = @(302)
    'auth'      = @(302)
    'home'      = @(200)
}

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

function Test-Site {
    param([string]$Sub, [int[]]$Expect)

    $url = "https://$Sub.$Domain/"
    $state = @{ Ok = $false; Error = ''; Subject = ''; Issuer = '' }

    $handler = New-Object System.Net.Http.HttpClientHandler
    $handler.AllowAutoRedirect = $false
    # 默认校验，但把证书信息留下来，出错时能直接看出是「没装 CA」还是「域名不对」
    $handler.ServerCertificateCustomValidationCallback = {
        param($request, $cert, $chain, $errors)
        $state.Ok = ($errors -eq [System.Net.Security.SslPolicyErrors]::None)
        $state.Error = "$errors"
        if ($cert) {
            $state.Subject = $cert.Subject
            $state.Issuer = $cert.Issuer
        }
        return $state.Ok
    }

    $client = New-Object System.Net.Http.HttpClient($handler)
    $client.Timeout = [TimeSpan]::FromSeconds(20)

    $code = -1
    try {
        $response = $client.GetAsync($url).GetAwaiter().GetResult()
        $code = [int]$response.StatusCode
    } catch {
        $code = -1
        $message = $_.Exception.GetBaseException().Message
        if (-not $state.Ok) {
            $failures.Add("$Sub`: 证书校验失败（$($state.Error)）——根证书没导入？")
        } else {
            $failures.Add("$Sub`: 请求失败 —— $message")
        }
    } finally {
        $client.Dispose()
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
        $flag, $Sub, $code, ($Expect -join '/'), $state.Issuer) -ForegroundColor $colour
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
