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
    [string]$GatewayIp = '192.0.2.10'
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# 子域 -> 允许的状态码（任一命中即通过）。判定口径以 #86 之后的真实架构为准：
#   jenkins / ldapadmin 已「摘网关 auth」，各自带登录：
#     jenkins   根路径匿名 403（Jenkins 自己拒），/login 是 200 登录页
#     ldapadmin 根路径 200，因为返回的就是自己的 LDAP 登录页
#   仍在网关侧的只有 docs（302 跳 oauth2）。
# 旧口径（jenkins/ldapadmin 一律 302）是 #86 之前的值，照它判会在正确环境上必红。
$Expectations = [ordered]@{
    'jenkins'   = @(302, 403)
    'nexus'     = @(200)
    'ldapadmin' = @(200)
    'dex'       = @(200)
    'auth'      = @(302)
    'home'      = @(200)
}

# 只验状态、不要求本机 hosts 的站点：docs 是唯一走网关认证的站点，
# 但它不在上面那 6 条标准 hosts 记录里（老机器不一定加了 docs 那条），
# 所以单独列，避免把「没加 hosts」误报成「站点挂了」。
$ExtraSites = [ordered]@{ 'docs' = @(302) }

# 子域 -> 探测路径（缺省是 /）
$ProbePaths = @{ 'dex' = '/dex/healthz' }

# 附加的「正面判据」：光看状态码只能证明「没给内容」，证明不了「应用活着且能登录」。
# 这几条必须是 200。
$PositiveChecks = [ordered]@{
    'jenkins' = '/login'
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

function Get-RemoteChainRoot {
    <#
        取服务端实际下发证书链的链尾（根证书）。
        回调里一律 return $true：这里只要链结构，不做信任判定 ——
        信任判定交给 Test-RootCa 与 Test-Site，各管一件事。
    #>
    param([string]$HostName)

    $script:remoteChain = $null
    $script:remoteRootCert = $null
    $tcp = $null
    $ssl = $null
    try {
        $tcp = New-Object System.Net.Sockets.TcpClient
        $tcp.Connect($HostName, 443)
        $ssl = New-Object System.Net.Security.SslStream($tcp.GetStream(), $false, {
            param($sender, $cert, $chain, $errors)
            # ★ 必须在回调**内部**取链：握手结束后 $chain.ChainElements 会被清空
            #   （实测 Count 由 3 变 0），事后读就是 null —— 会误判成「取不到链」。
            if ($chain -and $chain.ChainElements.Count -gt 0) {
                $script:remoteRootCert = $chain.ChainElements[$chain.ChainElements.Count - 1].Certificate
            }
            return $true
        })
        $ssl.AuthenticateAsClient($HostName) | Out-Null
        return $script:remoteRootCert
    } catch {
        $script:chainError = $_.Exception.Message
        return $null
    } finally {
        if ($ssl) { $ssl.Dispose() }
        if ($tcp) { $tcp.Close() }
    }
}

function Test-RootCa {
    <#
        判据必须是「服务端现在用的那把根，在本机机器级受信存储里」——
        不能只判「存在任一 Caddy 根证书」。

        ★ 2026-11-11 真机踩到：CA 在 11-03 重建过（AF45B583），
          而机器级存储里留的是 10-31 的旧根（FAA77064），新根只进了
          CurrentUser\Root。旧判据「找到任一 Caddy 根就通过」于是打出
          「根证书 FAA77064」并判绿 —— 当前用户浏览器能用，但换用户 /
          服务账户 / 提升权限的进程一律证书告警，且验收完全没发现。

        做法：用 SslStream 拿服务端实际下发的链，取链尾（根），再比对本机两处存储。
    #>
    # ★ Keys 在 PS 5.1 里是 KeyCollection，直接 [0] 取不到单个元素（会把集合当字符串拼），
    #   必须先 @() 物化成数组 —— 否则这里传出去的主机名是整串，Connect 报「不知道这样的主机」。
    $firstSub = @($Expectations.Keys)[0]
    $remoteRoot = Get-RemoteChainRoot -HostName "$firstSub.$Domain"
    if (-not $remoteRoot) {
        # 拿不到远端链时退回「存在性」判据，但要说明这是降级判定
        $any = Get-ChildItem Cert:\LocalMachine\Root |
            Where-Object { $_.Subject -like '*Caddy Local Authority*' }
        if ($any) {
            Write-Host ("  [WARN] 无法取得服务端实际证书链（{0}），降级为存在性判定：{1}" -f
                $script:chainError, $any[0].Thumbprint) -ForegroundColor Yellow
            return $true
        }
        $failures.Add('「受信任的根证书颁发机构」里没有 Caddy Local Authority 根证书')
        return $false
    }

    $machine = @(Get-ChildItem Cert:\LocalMachine\Root |
        Where-Object { $_.Thumbprint -eq $remoteRoot.Thumbprint })
    $user = @(Get-ChildItem Cert:\CurrentUser\Root |
        Where-Object { $_.Thumbprint -eq $remoteRoot.Thumbprint })

    Write-Host ("  服务端在用根：{0}" -f $remoteRoot.Subject) -ForegroundColor DarkGray
    Write-Host ("  指纹        ：{0}（有效期至 {1:yyyy-MM-dd}）" -f
        $remoteRoot.Thumbprint, $remoteRoot.NotAfter) -ForegroundColor DarkGray

    if ($machine.Count -eq 0) {
        # 顺便把机器级里那把过期的揪出来，否则用户会以为「我已经装过了」
        $stale = @(Get-ChildItem Cert:\LocalMachine\Root |
            Where-Object { $_.Subject -like '*Caddy Local Authority*' -and $_.Thumbprint -ne $remoteRoot.Thumbprint })
        foreach ($s in $stale) {
            $failures.Add("机器级受信存储里是过期根证书 $($s.Thumbprint)（{0:yyyy-MM-dd} 签发），服务端已不用它" -f $s.NotBefore)
        }
        $where = if ($user.Count -gt 0) { '只装在「当前用户」存储' } else { '未安装' }
        $failures.Add("当前 CA 根证书 $($remoteRoot.Thumbprint) $where，未装进机器级「受信任的根证书颁发机构」；换用户或服务账户访问会证书告警")
        return $false
    }

    Write-Host '  已在机器级受信存储' -ForegroundColor Green
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

function Test-DnsResolvable {
    param([string]$HostName)
    # hosts 命中时 Dns.GetHostAddresses 也会返回结果；解析不到会抛异常。
    # 这里只判「能不能拿到地址」，连不连得上交给 Test-Site。
    try {
        $null = [System.Net.Dns]::GetHostAddresses($HostName)
        return $true
    } catch {
        return $false
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
if ($failures.Count -eq 0) {
    Write-Host ("  {0} 条记录齐全" -f $Expectations.Keys.Count) -ForegroundColor Green
}

Write-Host '== 2. 根证书 ==' -ForegroundColor Cyan
[void](Test-RootCa)

Write-Host '== 3. 站点（状态码 + 证书链）==' -ForegroundColor Cyan
foreach ($sub in $Expectations.Keys) {
    [void](Test-Site -Sub $sub -Expect $Expectations[$sub])
}
foreach ($sub in $ExtraSites.Keys) {
    # 本机解析不到就先判「未配置」，不要报成站点故障：
    # 标准契约是 6 条 hosts，docs 不在其中，没加就必然解析失败。
    # 报 FAIL 会把人引向「网关坏了」的错误结论。
    if (-not (Test-DnsResolvable -HostName "$sub.$Domain")) {
        Write-Host ("  [SKIP] {0,-10}    -  本机未配置该域名解析（非故障；需要时在 hosts 补一条）" -f $sub) -ForegroundColor Yellow
        continue
    }
    [void](Test-Site -Sub $sub -Expect $ExtraSites[$sub])
}

# 正面判据：状态码只能证明「没给内容」，证明不了「能登录」。
foreach ($sub in $PositiveChecks.Keys) {
    $hostName = "$sub.$Domain"
    $url = "https://$hostName$($PositiveChecks[$sub])"
    $pcode = -1
    $preq = $null
    try {
        $preq = [System.Net.HttpWebRequest]::Create($url)
        $preq.AllowAutoRedirect = $false
        $preq.Timeout = 20000
        $preq.UserAgent = 'orgflow-acceptance'
        $presp = $preq.GetResponse()
        $pcode = [int]$presp.StatusCode
        $presp.Close()
    } catch [System.Net.WebException] {
        if ($_.Exception.Response) {
            $pcode = [int]$_.Exception.Response.StatusCode
            $_.Exception.Response.Close()
        }
    } finally {
        if ($preq) { $preq.Abort() }
    }
    if ($pcode -eq 200) {
        Write-Host ("  [OK  ] {0,-10} {1,4}  登录页可达 {2}" -f $sub, $pcode, $PositiveChecks[$sub]) -ForegroundColor Green
    } else {
        $failures.Add("$sub`: 登录页 $($PositiveChecks[$sub]) 返回 $pcode，期望 200（应用没起来或反代断了）")
        Write-Host ("  [FAIL] {0,-10} {1,4}  登录页 {2}" -f $sub, $pcode, $PositiveChecks[$sub]) -ForegroundColor Red
    }
}

Write-Host ''
if ($failures.Count -gt 0) {
    Write-Host "验收未通过，$($failures.Count) 项问题：" -ForegroundColor Red
    $failures | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    exit 1
}

Write-Host '验收全部通过。' -ForegroundColor Green
exit 0
