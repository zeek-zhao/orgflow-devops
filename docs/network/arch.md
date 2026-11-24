# 网络架构与分层排查（DOC-02）

## 拓扑

```
公网/Tailnet
    │  TLS（Funnel 边缘终止，或 Caddy 直接终结）
    ▼
Caddy（唯一入口，192.168.90.10）
    ├─ home.DOMAIN      → homepage:3000   (192.168.90.11)
    ├─ ldapadmin.DOMAIN → ldapadmin:80    (192.168.90.12)
    ├─ router.DOMAIN    → router:8080     (192.168.90.14)
    └─ :PUBLIC_PORT 按 path 反代（公网总览/healthz/home//ldapadmin//router//caddy/）

内网 docker 网桥 orgflow（192.168.90.0/24）：
    dnsmasq .15 (53/udp)   ldap .13 (389)   certs-init 一次性
```

## 固定 IP 表

| 服务 | 固定 IP | 内部端口 | 隔离端口 |
|---|---|---|---|
| caddy | .10 | 80/443/2019 | 8080/8443 |
| homepage | .11 | 3000 | 8082 |
| ldapadmin | .12 | 80 | 8081 |
| ldap | .13 | 389 | 3389 |
| router | .14 | 8080 | 8083 |
| dnsmasq | .15 | 53/udp | 5353 |
| certs-init | 动态 | — | — |

## 端口表

| 端口 | 服务 | 暴露范围 |
|---|---|---|
| 80/443 | caddy | 宿主（唯一入口） |
| 2019 | caddy admin | 宿主（admin API） |
| 18081 | caddy 公网 path 入口 | Funnel 转发 |
| 各隔离端口 | 单服务 | 宿主（单服务启动用） |

## 分层排查决策树

1. **公网进不来** → 查 `tailscale funnel status` / 安全组 80/443 → 查 Caddy `:PUBLIC_PORT` handle。
2. **域名不解析** → `dig @127.0.0.1 -p 5353 home.DOMAIN` → 查 dnsmasq `address=/.DOMAIN/` 指向的 `GATEWAY_IP`。
3. **站点 502** → `curl :2019/config/` 看 upstream 是否指向正确服务名（homepage 不是 home）→ 查后端容器是否 healthy。
4. **证书告警** → internal 模式需装根证书（见证书与CA.md）；acme 模式查 80/443 可达。
5. **容器 unhealthy** → `bash status.sh` → `docker logs of-<svc>` → 对照服务手册故障排查段。
