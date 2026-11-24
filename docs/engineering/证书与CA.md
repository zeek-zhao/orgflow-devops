# 证书与 CA（DOC-04）

## 模式

| 模式 | 说明 | 适用 |
|---|---|---|
| internal + Funnel（默认） | 内网 CA 自签（`*.DOMAIN`），公网由 Tailscale Funnel 边缘用合法 `*.ts.net` 证书终止 TLS，Caddy 只做明文反代 | 当前默认部署：沙箱/无公网 IP/无自有公网域名 |
| acme（可选生产） | Caddy 直接监听公网 `:443`，自动向公网 CA 申请证书 | 有可解析到本机的公网域名 + 80/443 放行 |

**默认采用 internal + Funnel**：公网入口走 Funnel 边缘终止 TLS，回源明文 `:PUBLIC_PORT`（默认 18081）；内网站点用 certs-init 签发的内部 CA 证书，SAN 覆盖 `*.DOMAIN` 与各子域。这条路已在沙箱实测可用，无需公网 IP。

**切到 acme 可选生产模式的启用条件**（当前默认不启用）：① 有一个可解析到本机公网 IP 的域名（如 `org-devops.com`）；② 80/443 入站放行；③ 将 `DOMAIN` 设为该域名、令 Caddy 直接监听 `:443` 并去掉 Funnel 转发。沙箱不含条件 ①，强切会导致部署不可达，故仅作为文档化的生产选项，不在默认路径中执行。详见 `records/ADR-01-Tailscale接入.md` 与 `records/ADR-02-内部CA-vs-ACME.md`。

## 签发流程

1. `certs-init`（复用 router 镜像，含 openssl/bash）挂 `gen-ca.sh` 到 ca-data 卷。
2. 生成根 CA（`ca.crt` / `ca.key`），签发站点证书（`site.crt` / `site.key`），SAN = `*.$DOMAIN`。
3. Caddy 挂 `ca-data:/ca:ro`，站点块 `tls /ca/site.crt /ca/site.key`。
4. 幂等：已存在证书不重签；`make ca-rotate` 强制重签。

## 四端安装根证书

```bash
make ca            # 导出根证书到 out/
# Linux: 放到 /usr/local/share/ca-certificates/ 后 update-ca-certificates
# macOS: 钥匙串导入并设信任
# Windows: certmgr 导入到「受信任的根证书颁发机构」
# 浏览器: Chrome/Firefox 证书设置里导入
```

## 轮换

`make ca-rotate` 重签后，所有客户端需重新安装根证书。根证书有效期与轮换记录见服务手册 caddy.md。
