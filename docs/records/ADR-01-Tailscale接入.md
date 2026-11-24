# ADR-01：公网入口采用 Tailscale Funnel + Caddy 唯一入口

| 项 | 值 |
|---|---|
| 状态 | 已接受 |
| 日期 | 2026-11-24 |
| 起因 | 沙箱无公网 IP / 端口映射；需在公网看到每个服务 |
| 影响面 | caddy、funnel-up.sh、docs/公网访问.md |

## 背景

沙箱主机只有内网地址，无公网 IP，也无法配置 DNS 指向。早期尝试直接暴露各服务端口不可行。当时不知道 Tailscale Funnel 是否支持多域名——后来确认 Funnel 只给一个 `*.ts.net` 域名。

## 决策

主机加入 tailnet，用 `tailscale funnel` 暴露一个域名；该域名指向 Caddy 的唯一公网入口（`:PUBLIC_PORT`，纯 HTTP，TLS 在 Funnel 边缘终止），由 Caddy 按 path 反代到各服务，并提供总览页与健康探针。所有服务只经 Caddy 暴露，不各自开公网端口。

## 放弃的方案

| 方案 | 不选的理由 | 什么条件下值得重提 |
|---|---|---|
| 各服务直接映射公网端口 | 无公网 IP；端口分散难管、无统一 TLS | 有公网 IP 且服务少时 |
| 公网 DNS + Caddy 直接 acme | 沙箱无法解析自有域名到本机 | 有可解析公网域名时（可作主通道，Funnel 退为备选） |

## 后果

- **变好的**：一个域名看到全部服务；TLS 由 Funnel 托管；服务不直接暴露。
- **变差的**：单一域名只能按 path 区分（非标准子域）；依赖 tailnet 在线。
- **需要跟着改的**：Caddyfile 公网 handle、funnel-up.sh 幂等、homepage 白名单 PUBLIC_HOST。

## 验证方式

`curl -s https://<PUBLIC_HOST>/healthz` 返回 200；`/`（HomePage 门面）、`/ldapadmin/`、`/router/routes`、`/_next/static/*` 各 200；`/caddy/*` 公网不可达（安全收紧，真机人工验收 AC-21）。
