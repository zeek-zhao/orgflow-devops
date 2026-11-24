# 证书与 CA（DOC-04）

## 模式

| 模式 | 说明 | 适用 |
|---|---|---|
| acme（默认） | Caddy 自动向公网 CA 申请证书，浏览器无告警 | 有公网域名 + 80/443 可达 |
| internal | 内部 CA 自签，需客户端装根证书 | 内网/断网环境 |

本底座默认 internal（certs-init 用内部 CA 签发到共享卷 ca-data），SAN 覆盖 `*.DOMAIN` 与各子域。

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
