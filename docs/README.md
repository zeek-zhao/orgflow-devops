# orgflow M0 最小 DevOps 底座 · 文档入口

> 7 容器单机自托管底座：DNS → 证书 → Caddy 唯一入口 → OpenLDAP → HomePage → Router。
> 全部镜像 @sha256 锁定，配置真源单一（.env 的 DOMAIN），一功能一 Issue 一 PR。

## 是什么

在一台云主机上用 Docker Compose 起一套最小 DevOps 底座，7 个容器按依赖顺序启动：

| # | 服务 | 职责 | 长驻 |
|---|---|---|---|
| 1 | dnsmasq | `*.DOMAIN` → Caddy 固定 IP | 是 |
| 2 | certs-init | 内部 CA + 站点证书签发（exit 0） | 否 |
| 3 | caddy | 唯一入口，按 Host 分站点 + 公网 path 反代 | 是 |
| 4 | ldap | OpenLDAP 身份目录 | 是 |
| 5 | ldapadmin | phpLDAPadmin 管理页 | 是 |
| 6 | homepage | 统一面板 | 是 |
| 7 | router | routes.yaml 渲染 + Caddy reload | 是 |

## 前置

- Docker 27 + Compose v2；Linux 云主机；端口 80/443 放行。
- 可选 Tailscale（公网入口走 Funnel）；可选自有域名指向本机公网 IP。

## 5 分钟起

```bash
cp .env.example .env          # 改 DOMAIN（= GATEWAY_DOMAIN）一处
make render                   # 渲染配置产物
make check                    # 静态门禁（无 docker）
make up                       # 顺序启动，失败即停（五段输出）
make status                   # 查看健康状态
make verify                   # 全量验收矩阵 AC-1~22
```

## 入口清单

| 入口 | 地址 | 说明 |
|---|---|---|
| 统一面板（内网） | `https://home.DOMAIN/` | 默认首页 |
| LDAP 管理（内网） | `https://ldapadmin.DOMAIN/` | 需登录 |
| 路由状态（内网） | `https://router.DOMAIN/` | /healthz /render |
| 公网入口（默认） | `https://PUBLIC_HOST/` | Tailscale Funnel 边缘 TLS + Caddy 按 path 反代；`/` 即 HomePage 门面 |
| 公网入口（可选生产） | Caddy 直听 `:443` + acme | 需可解析公网域名 + 80/443，见 `engineering/证书与CA.md` |
| 网关域名真源 | `.env` 的 `DOMAIN` | 改一处全链路跟随 |

> 默认公网路径：Funnel 边缘终止 TLS → 明文 `:PUBLIC_PORT`（18081）→ Caddy；admin（`:2019`）只绑内网，公网无 `/caddy/*`。

## 文档地图

- 网络拓扑与排查：[network/arch.md](network/arch.md)
- 启动顺序：[engineering/启动顺序.md](engineering/启动顺序.md)
- 证书与 CA：[engineering/证书与CA.md](engineering/证书与CA.md)
- 路由注册：[engineering/路由注册.md](engineering/路由注册.md)
- 镜像与供应链：[engineering/镜像与供应链.md](engineering/镜像与供应链.md)
- 使用说明：[engineering/使用说明.md](engineering/使用说明.md)
- 排障：[engineering/排障.md](engineering/排障.md)
- 架构决策记录：[records/ADR-*.md](records/)
- 服务手册：[services/](services/)
- 文档登记册：[文档登记册.md](文档登记册.md)
