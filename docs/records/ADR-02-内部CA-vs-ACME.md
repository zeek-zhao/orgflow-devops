# ADR-02：内网站点用内部 CA 自签，公网入口用边缘 TLS

| 项 | 值 |
|---|---|
| 状态 | 已接受 |
| 日期 | 2026-11-24 |
| 起因 | 内网域名 `*.DOMAIN` 无法向公网 CA 申请证书 |
| 影响面 | certs-init、caddy、四端客户端 |

## 背景

内网服务用 `*.DOMAIN`（如 org-devops.local），公网 CA 不会给 `.local` 签证书。沙箱又无固定公网 IP 做 acme HTTP-01 验证。需要一套内网可验证、可迁移的证书方案。

## 决策

certs-init 用仓库自带内部 CA 签发站点证书（SAN 含 `*.DOMAIN` 与各子域），写入共享卷 ca-data，Caddy 内网站点用该证书。公网入口走 Tailscale Funnel，TLS 在 Funnel 边缘用合法 `*.ts.net` 证书终止，Caddy 只做纯 HTTP 反代。即「内网自签 + 公网边缘 TLS」混合。

## 放弃的方案

| 方案 | 不选的理由 | 什么条件下值得重提 |
|---|---|---|
| 全站 acme | `.local` 域名无法验证；无公网 DNS/IP | 换成可解析公网域名且放行 80/443（v1.0 的 acme 模式） |
| Caddy 自签 local_certs | down -v 删卷换根证书，客户端要重装 | 临时开发环境 |
| 公网 CA 签内网域 | CA 不给保留域/内网域签发 |  nunca |

## 后果

- **变好的**：内网零外网依赖；证书可迁移（CA 私钥在 secrets，根证书入库）。
- **变差的**：客户端需装根证书，否则告警；轮换要重新安装。
- **需要跟着改的**：证书与CA.md、make ca / ca-rotate、Caddyfile tls 行。

## 验证方式

`openssl x509 -in config/ca/*.crt -noout -text | grep -A1 'Subject Alternative Name'` 含 `*.DOMAIN`；装根证书后浏览器无告警（AC-19 人工）。
