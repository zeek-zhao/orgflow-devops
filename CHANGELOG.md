# Changelog

本文件记录 orgflow-devops（M0 最小 DevOps 底座）的版本变更。格式遵循「保持一个版本一段、新增在上」的轻量约定。

## [m0-v1.1] — 待发布（R6~R8）

> 分支 `feat/m0-release`，tag 待打。本轮为展示层优化与清理，不动 `main`、不重建网络/数据卷。

### Added
- `CHANGELOG.md`、`docs/运维/备份与恢复.md`、`docs/运维/升级与回滚.md`、`docs/运维/安全基线.md`（R8 文档补漏）。

### Changed
- **R6 HomePage 展示层重构**（Closes #241，PR #242）：
  - 分组改名：`局域网服务状态` → `服务状态`、`域名入口` → `公网入口`，`settings.yaml` layout 键同步。
  - 服务状态组 6 张全保留；公网入口组改为 4 张，按 `public_path` 非 `/status`/非 `/none` 规则筛选真实入口，删除 DNS/LDAP/Caddy 三张「点进去还是 /status」的假入口卡，固定追加「状态总览 → /status」。
  - 移除 `[lan][domain][LAN][DOMAIN][NO-UI]` 方括号前缀；description 统一为「一句中文用途 · 协议/端口」；名称去冗余后缀（统一面板→统一入口、LDAP 管理页→LDAP 管理、路由状态→路由服务）。
  - `custom.css` 分组标题与卡片间距微调；bats 断言同步为 6+4 卡与新组名。
- **R7 分支清理**：远端 14 条分支收敛到 2 条（`main`、`feat/m0-release`）；4 条未并入的历史尝试分支归档为 `archive/*` tag 后删除。

## [m0-v1.0] — 2026-11-24

> 交付主线 `feat/m0-release` @ `3d318c0`，tag `m0-v1.0`。`main` 保持只读历史参考。

### Added
- 从零构建的 7 服务最小 DevOps 底座：DNS（dnsmasq）→ 证书（certs-init）→ 网关（Caddy）→ 目录（OpenLDAP）→ 面板（HomePage）→ 管理页（ldapadmin）→ 路由（router）。
- **单域名路径型入口**：HomePage 占根 `/`，`/ldapadmin/`、`/router/`、`/status` 走路径前缀；Tailscale Funnel 在边缘终止 TLS 后回源 Caddy `:PUBLIC_PORT`，无子域 vhost。
- 逐服务 compose（`services/<svc>/compose.yml`）、`up.sh` 按 `services/manifest.tsv` 顺序启动、配置即代码（域名/端口用 `.env` 占位符）。

### Changed
- **R1 公网信息泄漏收口**（Closes #238）：`/api/services`、`/api/widgets` 对公网返回 403（Host 判定）；`POST /router/render` 403；`/router/` 308。线上实测公网不再泄漏内网 IP/宿主指标。
- **R2 文档与事实对齐**（Closes #239）：启动顺序、分支口径、变更台账、LDAP 口令等五处。
- **R3 HomePage 卡片标签**（Closes #240）：manifest 增加 `tags` 列（当时降级为 description 前缀；R6 起不再参与展示）。
- **R4 流程收口**：分支策略改为 release 体系，关闭遗留 PR #207。

### Security / Ops
- **镜像双模式**：默认走 GHCR `@sha256` digest（`USE_LOCAL_IMAGES=0`，零停机）；本地自建（`USE_LOCAL_IMAGES=1`）为可选模式，须 lock 无 PENDING 且本地镜像存在，否则告警回退 GHCR。
- **公网暴露面**：仅 Tailscale Funnel 一个入口；Caddy admin `:2019` 只绑内网，LDAP `389` 不出网。
