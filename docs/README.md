# orgflow M0 最小 DevOps 底座 · 文档入口

> 状态：适用 | 最后核对：2026-11-24 | 对应分支：feat/m0-v2


> 7 服务单机自托管底座：DNS → 证书 → Caddy 唯一入口 → OpenLDAP → HomePage → Router。
> 全部镜像 @sha256 锁定，逐服务 compose 按 manifest 顺序拉起，一功能一 Issue 一 PR。

## 是什么

在一台云主机上起一套最小 DevOps 底座，7 个服务按依赖顺序启动：

| # | 服务 | 职责 | 长驻 |
|---|---|---|---|
| 1 | dnsmasq | `*.DOMAIN` → Caddy 固定 IP | 是 |
| 2 | certs-init | 内部 CA + 站点证书签发（exit 0） | 否 |
| 3 | caddy | 唯一入口，路径反代 + 内网 TLS 站点 | 是 |
| 4 | ldap | OpenLDAP 身份目录 | 是 |
| 5 | ldapadmin | phpLDAPadmin 管理页 | 是 |
| 6 | homepage | 占根 `/` 的统一面板（双分组卡片） | 是 |
| 7 | router | routes.yaml 渲染 + Caddy reload | 是 |

## 前置

- Docker 27 + Compose v2；Linux 云主机；端口 80/443 放行。
- 可选 Tailscale（公网入口走 Funnel）；可选自有域名指向本机公网 IP。

## 5 分钟起

```bash
cp .env.example .env          # 改 DOMAIN（= GATEWAY_DOMAIN）一处
make render                   # 渲染配置产物（含 HomePage 卡片）
make check                    # 静态门禁（无 docker）
make up                       # 按 manifest 顺序逐服务启动，失败即停
make status                   # 查看健康状态
make verify                   # 全量验收矩阵 AC-1~22
```

## 入口清单

| 入口 | 地址 | 说明 |
|---|---|---|
| 统一面板（公网） | `https://PUBLIC_HOST/` | Tailscale Funnel 边缘 TLS + Caddy 路径反代；`/` 即 HomePage |
| LDAP 管理（公网） | `https://PUBLIC_HOST/ldapadmin/` | 需登录 |
| 路由状态（公网） | `https://PUBLIC_HOST/router/healthz` | 健康探针 |
| 内网面板 | `https://home.DOMAIN/` | 内网 TLS 站点 |
| 可选生产入口 | Caddy 直听 `:443` + acme | 需可解析公网域名 + 80/443，见[证书与CA](运维/证书与CA.md) |
| 网关域名真源 | `.env` 的 `DOMAIN` | 改一处全链路跟随 |

> 默认公网路径：Funnel 边缘终止 TLS → 明文 `:PUBLIC_PORT`（18081）→ Caddy；admin（`:2019`）只绑内网，公网无 `/caddy/*`。

## 按角色阅读

| 你是 | 先读 |
|---|---|
| 想了解整体 | [架构总览](架构.md) |
| 想部署/运维 | [使用说明](使用说明.md) |
| 想改某个服务 | `docs/services/` 下对应手册 |
| 想知道治理规则 | `docs/records/M0-治理约定.md` |

## 目录索引

- 架构总览：[架构.md](架构.md)（吸收原 network/arch.md：拓扑、固定 IP、分层排查）
- 使用说明：[使用说明.md](使用说明.md)（已吸收旧「使用说明（工程）」：登录、改域名）
- 启动顺序：[运维/启动顺序.md](运维/启动顺序.md)
- 证书与 CA：[运维/证书与CA.md](运维/证书与CA.md)
- 路由注册：[运维/路由注册.md](运维/路由注册.md)
- 镜像与供应链：[运维/镜像与供应链.md](运维/镜像与供应链.md)
- 排障：[运维/排障.md](运维/排障.md)
- 公网访问：[运维/公网访问.md](运维/公网访问.md)
- 架构决策记录：[records/ADR-*.md](records/)
- 服务手册：[services/](services/)

## 门禁

- `make check`：快检查（记录/镜像/基底/文档/配置）
- `make verify`：全量验收矩阵（静态必过，行为项需真机）

## 附录：文档登记册（IEEE 828 配置标识）

> 一篇文档在不在这里、什么状态，全看这张表。门禁 `bash scripts/check-docs.sh` 从本表第 3 列解析路径，做路径双向一致校验。运行产物（执行日志/台账/验收单）不登记；本表自身不登记。

| DOC-ID | 标题 | 路径 | 层级 | 状态 | 负责人 | 复审(月) | 关联 |
|---|---|---|---|---|---|---|---|
| DOC-E-001 | 文档入口（README，含文档地图+登记册） | docs/README.md | 入口 | review | zeek.zhao | 6 | T9 |
| DOC-E-002 | 架构总览（含 network/arch） | docs/架构.md | 入口 | review | zeek.zhao | 6 | T4 T7 |
| DOC-P-001 | 使用说明（含工程使用说明） | docs/使用说明.md | 规程 | review | zeek.zhao | 6 | T8 |
| DOC-P-002 | M0 治理约定（分支/PR/记录留存） | docs/records/M0-治理约定.md | 规程 | review | zeek.zhao | 6 | T0 |
| DOC-P-003 | 公网访问（Tailscale Funnel + Caddy 唯一入口） | docs/运维/公网访问.md | 规程 | review | zeek.zhao | 6 | Funnel |
| DOC-R-001 | 问题解决方案记录 | docs/records/问题解决方案记录.md | 参考 | review | zeek.zhao | 6 | 真机 |
| DOC-E-003 | 镜像与供应链（双层 digest） | docs/运维/镜像与供应链.md | 参考 | review | zeek.zhao | 6 | T2 |
| DOC-E-005 | 启动顺序 | docs/运维/启动顺序.md | 规程 | review | zeek.zhao | 6 | T8 |
| DOC-E-006 | 证书与 CA | docs/运维/证书与CA.md | 规程 | review | zeek.zhao | 6 | T4 |
| DOC-E-007 | 路由注册 | docs/运维/路由注册.md | 规程 | review | zeek.zhao | 6 | T7 |
| DOC-E-009 | 排障 | docs/运维/排障.md | 参考 | review | zeek.zhao | 6 | T9 |
| DOC-A-001 | ADR-01 Tailscale 接入 | docs/records/ADR-01-Tailscale接入.md | 参考 | approved | zeek.zhao | 6 | 公网 |
| DOC-A-002 | ADR-02 内部 CA vs ACME | docs/records/ADR-02-内部CA-vs-ACME.md | 参考 | approved | zeek.zhao | 6 | T4 |
| DOC-A-003 | ADR-03 双层 digest | docs/records/ADR-03-双层digest.md | 参考 | approved | zeek.zhao | 6 | T2 |
| DOC-S-001 | dnsmasq 服务手册 | docs/services/dnsmasq.md | 参考 | review | zeek.zhao | 6 | T3 |
| DOC-S-002 | certs-init 服务手册 | docs/services/certs-init.md | 参考 | review | zeek.zhao | 6 | T4 |
| DOC-S-003 | caddy 服务手册 | docs/services/caddy.md | 参考 | review | zeek.zhao | 6 | T4 |
| DOC-S-004 | ldap 服务手册 | docs/services/ldap.md | 参考 | review | zeek.zhao | 6 | T5 |
| DOC-S-005 | ldapadmin 服务手册 | docs/services/ldapadmin.md | 参考 | review | zeek.zhao | 6 | T5 |
| DOC-S-006 | homepage 服务手册 | docs/services/homepage.md | 参考 | review | zeek.zhao | 6 | T6 |
| DOC-S-007 | router 服务手册 | docs/services/router.md | 参考 | review | zeek.zhao | 6 | T7 |
| DOC-P-004 | 分支与合并策略 | docs/records/分支与合并策略.md | 规程 | review | zeek.zhao | 6 | T12 |
