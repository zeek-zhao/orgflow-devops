<#
.SYNOPSIS
    在 Windows hosts 里增删指向网关的 8 条域名记录。

.DESCRIPTION
    用标记块包裹，删除时只删标记块内的行，绝不碰用户自己的记录。
    必须管理员运行（hosts 在 System32 下），acceptance.bat 会自动提权。

.NOTES
    ★ 是 8 条不是 6 条（#117 之后）。少了 auth 那条，jenkins / ldapadmin 未登录跳
      auth.<domain> 时浏览器会 DNS 断，表现成「一点登录就白屏」；
      docker / pypi 少了则对应仓库客户端连不上，而 Nexus 本身其实是好的。
#>
[CmdletBinding()]
param(
    [ValidateSet('Add', 'Remove')]
    [string]$Action = 'Add',
    # 192.0.2.10 是 RFC 5737 的文档示例地址，**不可路由**，只是占位。
    # 真实部署必须显式传 -GatewayIp <网关地址>，否则脚本会连一个不存在的主机。
    [string]$GatewayIp = '192.0.2.10',
    [string]$Domain = 'org-devops.com'
)

$ErrorActionPreference = 'Stop'

$HostsPath = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
$Begin = '# >>> orgflow-devops >>>'
$End = '# <<< orgflow-devops <<<'
# 6 条基础站点 + #117 的两个仓库站点 = 8 条。docs 刻意不在这里：
# 它走网关认证，但标准契约不含 docs（老机器不一定加了那条），
# 少了它只会让文档站不可达，不会让下面 8 条判错。
$Subdomains = @('jenkins', 'nexus', 'ldapadmin', 'dex', 'auth', 'home', 'docker', 'pypi')

function Assert-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw '需要管理员权限：直接运行 acceptance.bat（它会自己提权），或用管理员 PowerShell 跑本脚本。'
    }
}

Assert-Administrator

if (-not (Test-Path -LiteralPath $HostsPath)) {
    throw "找不到 hosts 文件：$HostsPath"
}

# hosts 没有扩展名也没有 BOM，按 ASCII 读写最稳。
# 写完必须保持无 BOM：带 BOM 时某些 Windows 版本会把 BOM 当成首行域名，解析失败。
$lines = @(Get-Content -LiteralPath $HostsPath -Encoding ASCII)

# 先剥掉旧标记块，保证幂等：重复跑不会把同一批记录叠两遍
$kept = New-Object System.Collections.Generic.List[string]
$inside = $false
foreach ($line in $lines) {
    if ($line.Trim() -eq $Begin) { $inside = $true; continue }
    if ($line.Trim() -eq $End) { $inside = $false; continue }
    if (-not $inside) { $kept.Add($line) }
}

if ($Action -eq 'Add') {
    $kept.Add('')
    $kept.Add($Begin)
    foreach ($sub in $Subdomains) {
        $kept.Add("$GatewayIp`t$sub.$Domain")
    }
    $kept.Add($End)
}

# 改之前先备份：hosts 改坏了会导致一堆莫名其妙的名字解析失败
$backup = "$HostsPath.bak-orgflow"
Copy-Item -LiteralPath $HostsPath -Destination $backup -Force

Set-Content -LiteralPath $HostsPath -Value $kept -Encoding ASCII

# 不清 DNS 缓存的话，刚加的记录可能几分钟都不生效，看起来像「脚本没起作用」
& ipconfig /flushdns | Out-Null

if ($Action -eq 'Add') {
    Write-Host ("已写入 {0} 条记录（指向 {1}）：" -f $Subdomains.Count, $GatewayIp) -ForegroundColor Green
    foreach ($sub in $Subdomains) {
        Write-Host ("  {0,-12} {1}.{2}" -f $sub, $sub, $Domain)
    }
} else {
    Write-Host '已移除 orgflow-devops 的 hosts 记录（其余行原样保留）。' -ForegroundColor Green
}
Write-Host "备份：$backup" -ForegroundColor DarkGray
Write-Host 'DNS 缓存已刷新。' -ForegroundColor DarkGray
