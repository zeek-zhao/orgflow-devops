# orgflow 最小 DevOps 底座 · 文档入口

> 状态：适用 | 最后核对：2026-11-26 | 对应分支：feat/m2-gerrit-cgit-harbor（M2.1 封版 m2.1-v1.0 + M2.2 启动）


> 13 服务单机自托管底座：M0 七服务（DNS → 证书 → Caddy 唯一入口 → OpenLDAP → HomePage → Router）+ M1 两服务（Jenkins controller + SSH agent）+ M2.1 两服务（Gerrit + cgit）+ M2.2 一服务（registry 轻量镜像仓库）+ M2.3 一服务（builder，rootless BuildKit）。Jenkins 手册见 [jenkins.md](services/jenkins.md)。
> 全部镜像 @sha256 / 内容哈希锁定，逐服务 compose 按 manifest 顺序拉起，一功能一 Issue 一 PR。

## 是什么

在一台云主机上起一套最小 DevOps 底座，13 个服务（12 常驻 + certs-init 一次性）按依赖顺序启动：

| # | 服务 | 职责 | 长驻 |
|---|---|---|---|
| 1 | dnsmasq | `*.DOMAIN` → Caddy 固定 IP | 是 |
| 2 | certs-init | 内部 CA + 站点证书签发（exit 0） | 否 |
| 3 | caddy | 唯一入口，路径反代 + 内网 TLS 站点 | 是 |
| 4 | ldap | OpenLDAP 身份目录 | 是 |
| 5 | ldapadmin | phpLDAPadmin 管理页 | 是 |
| 6 | homepage | 占根 `/` 的统一面板（双分组卡片） | 是 |
| 7 | router | routes.yaml 渲染 + Caddy reload | 是 |
| 8 | gerrit | Gerrit 代码评审 + Git（M2.1） | 是 |
| 9 | cgit | Gerrit 裸库只读 Web（M2.1） | 是 |
| 10 | registry | OCI 镜像仓库 + htpasswd（M2.2） | 是 |
| 11 | builder | rootless BuildKit 构建节点（M2.3） | 是 |

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
| 想提交代码评审 | [Gerrit 人工使用指南](使用手册/Gerrit-人工使用指南.md) |
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
- 备份与恢复：[运维/备份与恢复.md](运维/备份与恢复.md)
- 升级与回滚：[运维/升级与回滚.md](运维/升级与回滚.md)
- 安全基线：[运维/安全基线.md](运维/安全基线.md)
- 新增服务标准作业：[运维/新增服务标准作业.md](运维/新增服务标准作业.md)
- Gerrit 人工使用指南：[使用手册/Gerrit-人工使用指南.md](使用手册/Gerrit-人工使用指南.md)（登录/SSH key/clone/push/评审）
- 自检框架：[运维/自检框架.md](运维/自检框架.md)（checks.tsv / HTML 报告 / 加检查项）
- 构建资源配额：[运维/构建资源配额.md](运维/构建资源配额.md)（四项铁律 / quota-guard / Quota gate）
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
| DOC-R-002 | M2 封版记录（终验 7 条 + 一句话结论） | docs/records/M2-封版记录.md | 参考 | review | zeek.zhao | 6 | M2 封版 |
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
| DOC-S-008 | Jenkins controller 服务手册 | docs/services/jenkins.md | 参考 | review | zeek.zhao | 6 | M1-T7 |
| DOC-S-009 | Jenkins agent 服务手册 | docs/services/jenkins-agent.md | 参考 | review | zeek.zhao | 6 | M1-T7 |
| DOC-S-010 | Gerrit 服务手册 | docs/services/gerrit.md | 参考 | review | zeek.zhao | 6 | M2.1 |
| DOC-S-011 | cgit 服务手册 | docs/services/cgit.md | 参考 | review | zeek.zhao | 6 | M2.1 |
| DOC-S-012 | registry 服务手册 | docs/services/registry.md | 参考 | review | zeek.zhao | 6 | M2.2 |
| DOC-S-013 | builder 服务手册 | docs/services/builder.md | 参考 | review | zeek.zhao | 6 | M2.3 |
| DOC-P-004 | 分支与合并策略 | docs/records/分支与合并策略.md | 规程 | review | zeek.zhao | 6 | T12 |
| DOC-P-005 | 备份与恢复 | docs/运维/备份与恢复.md | 规程 | review | zeek.zhao | 6 | R8 |
| DOC-P-006 | 升级与回滚 | docs/运维/升级与回滚.md | 规程 | review | zeek.zhao | 6 | R8 |
| DOC-P-007 | 安全基线（公网暴露面） | docs/运维/安全基线.md | 规程 | review | zeek.zhao | 6 | R8 |
| DOC-E-010 | 新增服务标准作业（SOP） | docs/运维/新增服务标准作业.md | 规程 | review | zeek.zhao | 6 | M2.0-P4 |
| DOC-P-008 | Gerrit 人工使用指南（面向写代码的人） | docs/使用手册/Gerrit-人工使用指南.md | 规程 | review | zeek.zhao | 6 | M2.4-P2 |
| DOC-P-009 | 自检框架（checks.tsv / 报告 / 加检查项） | docs/运维/自检框架.md | 规程 | review | zeek.zhao | 6 | M2.4-P3 |
| DOC-E-011 | 构建资源配额（四项铁律 / quota-guard / Quota gate） | docs/运维/构建资源配额.md | 规程 | review | zeek.zhao | 6 | M2.5-P0 |
| DOC-P-010 | 容量与清理（disk-report / prune-images / 水位阈值） | docs/运维/容量与清理.md | 规程 | review | zeek.zhao | 6 | M3.0 |
