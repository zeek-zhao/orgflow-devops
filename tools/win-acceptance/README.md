# Windows 侧验收脚本

在 Windows 机器上完成「改 hosts + 装根证书 + 自检」这三步，替代之前散在桌面上的手工脚本。

## 用法

以**普通权限**打开 cmd（脚本会自己提权）：

```bat
acceptance.bat all      :: 一次做完：加 hosts → 拉并导入根证书 → 自检
acceptance.bat add      :: 只加 hosts
acceptance.bat trust    :: 只拉并导入根证书
acceptance.bat verify   :: 只读自检，不改任何东西
acceptance.bat remove   :: 删 hosts（只删自己的标记块，不碰你的其他记录）
```

`verify` 的期望不是「全部 200」：

| 站点 | 期望 | 说明 |
|---|---|---|
| `home` | 200 | 公开入口 |
| `nexus` | 200 | 公开 UI |
| `jenkins` | 302 | 受保护，未登录跳 oauth2 才是对的 |
| `ldapadmin` | 302 | 同上 |
| `dex` | 302 | 同上 |
| `auth` | 302 | 同上 |

受保护站点返回 200 反而是**漏了认证**，比 302 严重。

## hosts 是 6 条，不是 5 条

```
10.22.67.213  jenkins.org-devops.com
10.22.67.213  nexus.org-devops.com
10.22.67.213  ldapadmin.org-devops.com
10.22.67.213  dex.org-devops.com
10.22.67.213  auth.org-devops.com      ← 最容易漏这条
10.22.67.213  home.org-devops.com
```

少了 `auth` 那条，jenkins / ldapadmin 未登录跳 `auth.<domain>` 时浏览器会 DNS 断，
表现成「一点登录就白屏」，和证书问题长得几乎一样。

## 证书为什么不进仓库

根证书由 Caddy 在首次启动时生成。`docker compose down -v` 会**连卷一起删**，
CA 随之重建，之前导出的 `.crt` 立刻作废 —— 而症状是「浏览器又开始报警」，
很难联想到是 CA 换了。

所以脚本改为**运行时从网关机拉**：

```
ssh jenkins@10.22.67.213  →  cd ~/workbuddy/orgflow-devops
                          →  [ -s out/ca/root.crt ] || bash scripts/ca-install.sh --export
                          →  cat out/ca/root.crt
```

已经有证书文件时，可以跳过 ssh：

```powershell
Import-OrgflowRootCa.ps1 -CaFile D:\somewhere\root.crt
```

## 三个编码 / 换行陷阱

| 文件 | 编码 | 换行 | 写错的症状 |
|---|---|---|---|
| `*.bat` | **GBK(936)** | **CRLF** | UTF-8 → 中文乱码；LF → `goto`/`if` 块解析错乱，跑到一半静默退出 |
| `*.ps1` | **UTF-8 带 BOM** | **CRLF** | 无 BOM → 中文变乱码；LF → here-string 报奇怪的语法错 |

`.gitattributes` 里对 `*.bat` / `*.ps1` 显式声明了 `eol=crlf`（上面的 `* text=auto eol=lf`
会把它们冲成 LF）。**那条声明不能删。**

## 两个判据上的坑

- **不要用 `certutil -store` 判断证书是否已装**：失败时它返回负数 HRESULT
  （例如 `-2146893807`），cmd 的 `if errorlevel 1` 只认非负值，会误判成成功。
  本目录一律枚举 `Cert:\LocalMachine\Root`。
- **不要用 `X509Chain.Build()` 判证书链**：它只拿叶子证书，不会用服务端送来的中间证书，
  对 Caddy 这种「根 + 中间」结构会给出假阴性（`PartialChain`）。
  本目录用 `HttpClient` / `SslStream` 的默认校验，也就是浏览器的实际行为。

## 网关地址不是 10.22.67.213 时

三个脚本都接受参数，直接调 ps1：

```powershell
.\Set-OrgflowHosts.ps1 -Action Add -GatewayIp 192.168.1.50 -Domain example.test
.\Import-OrgflowRootCa.ps1 -GatewayIp 192.168.1.50
.\Test-OrgflowAcceptance.ps1 -Domain example.test -GatewayIp 192.168.1.50
```
