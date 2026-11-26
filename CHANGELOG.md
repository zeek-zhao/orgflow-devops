# Changelog

本文件记录 orgflow-devops（M0 最小 DevOps 底座 + M1 Jenkins）的版本变更。格式遵循「保持一个版本一段、新增在上」的轻量约定。

## [m2.1-v1.0] — 2026-11-26（M2.1 封版：Gerrit + cgit 上线，评审流 4/4 通过）

> 分支 `feat/m2-gerrit-cgit-harbor`，封版 tag `m2.1-v1.0` @ `fca5c19`。详见 `docs/records/执行日志/2026-11-26.md`。交付主线仍是 `feat/m0-release` / `feat/m1-jenkins` 的历史链，本 tag 标记 M2.1 功能面封版快照。

### Added
- **Gerrit 3.9 代码评审服务**：LDAP/osixia 统一身份接入（正确键 `username/password/supportAnonymous=false`），`accounts.visibility=NONE` 收紧账号枚举；业务仓 `orgflow-devops` 导入源码 188 文件为 commit `cba7f0b`；Web `:8443`、SSH `:29418`（Funnel 不转 TCP，tailnet/本机可达）。
- **cgit 1.2.3 浏览服务**：`/cgit/` 公网只读视图，`repo.` 显式白名单（排除 All-Projects/All-Users），`git-http-backend` 支持 smart-http clone；镜像 tag `ctx-e0643a8c475e`（内容哈希，GHCR + 南大代理中转）。
- **状态页/主页/门禁同步**：router `/status` 从 manifest 动态生成（9→11 服务含 gerrit/cgit）；主页补 Gerrit 公网入口；bats 新增 `S_gerrit.bats`/`S_cgit.bats`，verify-lan-all 判据接受安全 3xx。

### Verified
- **评审流 4/4 判据全绿**：HTTP 认证（ls-remote 非 401）、`refs/for/main` 接受（输出 `+/<id>`）、Change #1 浏览器/REST 可见、SSH `gerrit ls-projects` 列出业务仓。截图 `artifacts/m2.1/gerrit-review-open.png`。
- 全量门禁 `make check`/`check-all`/`test` 全绿；Jenkins verify-lan-all #14 SUCCESS 失败 0 项；公网 443/8443/`/status`=200。

### 边界
- Harbor/M2.2 未纳入本版：无容器/无配置，10000→18086 无后端；按施工文档 A/B 路线对比另起阶段。

## [m2.0-prep] — 2026-11-25（M2.0 前置治理 P1~P4，未封版）

> 分支 `feat/m1-jenkins`，基线 `m1-v1.0 @ 72c2f63`。详见 `docs/records/执行日志/2026-11-25-r8.md`。M2.1+ 服务部署待资源闸门决策（内存 5.62GiB < 8GiB）。

### Fixed
- **up.sh 假成功（M1 r7 遗留真正根因）**：`DC()` 未透传 `"$@"` 导致 compose 子命令被丢弃却退出 0；修复透传 + pull/up 捕获退出码打 stderr 末 15 行 + FORCE 分支 StartedAt 比对。坏镜像实测 exit 1 并打印错误，正常重建 StartedAt 变化。

### Added
- **端口三层模型（M2 §1）**：defaults.env 增 9 个端口变量（Funnel 443/8443/10000、回环 18085/18086、容器内 8080/29418/80/8080）；新增 `render-urls.sh` 生成 out/urls.env（公网 URL 单一真源）、`check-ports.sh` 六条门禁（非法 Funnel 口拦截、无字面端口硬编码）；make render / check-fast 接入。
- **资源盘点闸门**：`preflight.sh` 输出 nproc/内存/磁盘三项，全过 exit 0、任一不过 exit 3 建议降级 registry:2（不自动降级、等人定）。
- **服务脚手架**：`services/_template/` 三件套 + `new-service.sh`（生成骨架并打印手工 5 步）；镜像/静态门禁排除 `_template` 模板目录。

## [m1-v1.0] — 2026-11-25（M1 封版：终验 16/16 通过）

> 分支 `feat/m1-jenkins`，基线 `m1-v0.3` @ `df94483`。详见 `docs/records/执行日志/2026-11-25-r6.md`。
>
> 收口（r7）：`jenkins-devtest` 落入 `51-jenkins.ldif` 真源（卷清空可重建）+ `m1-v1.0` 移到收口终态提交 + 重建 router 使 render 模板与运行态一致（详见 `docs/records/执行日志/2026-11-25-r7.md`）。

### Fixed
- **状态页判据 7/8 假绿（终验发现）**：`services/router/server.py` 的 `GET /status` 补齐 `Status-Source: router` 头、HEAD 支持（`curl -sI` 200）与访问日志；表格增「容器」列列全 9 个 `of-*`（含 Jenkins/Agent），`grep -c 'of-'` = 9。此前 `/status` 实测 501/无头/无容器名，与 A 部分「已切 router」声称不符。server.py 为 bind mount，重建 router 容器即生效，镜像未变。

### Verified
- 全量拆除（保留 4 卷 + 1 网络，CA sha256 未变）后按 manifest 重建，16 条终验判据全部通过：容器/IP/DNS/入口/Jenkins 冷启/主题/agent/匿名/9 Job 全绿/定时/幂等/门禁。

## [m1-v0.3] — 2026-11-25（r5：门禁真转绿 + 镜像内容哈希 + 冗余清理）

> 分支 `feat/m1-jenkins`，基线 `m1-v0.2` @ `baa0e87`。不合并 main。详见 `docs/records/执行日志/2026-11-25-r5.md`。

### Fixed
- **门禁真转绿（P1）**：`tests/v2.env` 入库（`.gitignore` 白名单），修掉「沙箱假绿、干净克隆红」；r3 日志与 CHANGELOG 的假绿记录改真。`make check` 现 10 项全 ok。
- **upstreamDigest 口径统一（P5）**：dnsmasq/router/certs-init 由自建产物 manifest digest 改为 Dockerfile `FROM` 基底 digest，与其余行同义。

### Changed
- **镜像改内容哈希标识（P2）**：新增 `scripts/image-hash.sh`；M1 jenkins/agent 的 tag 改 `ctx-<12>`、imageId 改 `-`、contextSha256 为主标识；两个 compose 与 `images.env` 同步；`check-images.sh` 重写（扫描派生 + HASHED 强校验 + 删 source/PENDING）；CI 删 fill-pending 回填链路；删除 `build-images.sh`/`update-images-lock.sh`；Makefile `images-lock`→`images-hash`。反向门禁生效（改 Dockerfile 不更 lock → `make check` 红）。
- **摘除失败通知死代码（P3）**：无邮件/webhook 通道，删 `notify-feishu.sh` 与 Jenkinsfile `failure` 块，E2 暂缓。
- **状态页去重（P4）**：Caddy/router 内联 HTML 改为 `reverse_proxy router:8080`，router `GET /status` 为唯一真源（静态生效，运行时下次部署 reload）。
- **服务清单一致性门禁（P4）**：新增 `scripts/check-service-list.sh` 挂进 `make check`；`verify-service.groovy` 7→8 修漂移。
- **文档口径统一（P5）**：「7 服务/6 常驻」→「9 服务（8 常驻 + certs-init）」；jenkins.md scriptPath/镜像口径改正；镜像与供应链.md §3/§4 重写。

## [m1-v0.2] — 2026-11-25（M1 收口：主题生效 + 定时巡检 + 失败通知）

> 分支 `feat/m1-jenkins`，tag `m1-v0.2` @ `9e20dd4` 之后的本轮 commit。`m1-v0.1` 保留作历史（指向旧链，孤儿 tag），基线以本版为准。

### Fixed
- **深色主题真正生效（判据1，原 T7 高危）**：GHCR 新镜像 `sha-9e20dd4`（`sha256:459b0d97…43dfa`）含 `theme-manager`/`dark-theme` 插件；回填 `services/jenkins/compose.yml` digest 与 `tests/images.lock` imageId（`8ca8cb67…`），用新镜像重建 jenkins。公网 `/jenkins/appearance/` 显示 Dark、`disableUserThemes`，pluginManager 含两插件，UI 深色生效且用户不可改。
- **配置/镜像一致（判据2）**：compose digest == 线上 RepoDigest == lock imageId；`check-images --mode=lock` 零 PENDING。

### Added
- **E1 定时巡检**：`verify-lan-all.groovy` 加 `triggers { cron('H 2 * * *') }`（每日 02xx 随机分钟，保留手动触发）。
- **E2 失败通知**：新增 `ci/shared-library/bin/notify-feishu.sh` + Jenkinsfile `post.failure` 用 `withCredentials` 绑定 `feishu-webhook`（webhook 走 plain-credentials，不入库）；缺凭据优雅跳过，配置后失败即发。

### Notes
- Jenkins 重建必须走 `up.sh`（注入 agent 密钥），裸 `docker compose up` 会触发 JCasC `failed-boot-attempts` 崩溃循环——详见 `docs/records/执行日志/2026-11-25-r3.md`。
- 验收：9/9 Job 全绿、公网端点无回归。`make check` **当时未真绿**（§8 `tests/v2.env` 未入库，干净克隆红；沙箱因遗留文件假绿），已于 r5 §1 修复。E2 webhook 实测待用户提供飞书 webhook 凭据；E1 自动构建次日观察。

## [m1-v0.1] — 待发布（M1：Jenkins + Agent + 局域网检测）

> 分支 `feat/m1-jenkins`，从 `feat/m0-release` @ `0e5562c`（tag `m0-v1.1`）拉出；`main` 不动。

### Added
- **Jenkins controller**（M1-T1/T3/T5）：JCasC 唯一配置真源 `config/jenkins/jenkins.yaml`（LDAP 登录 + projectMatrix 授权 + SSH 节点 + 凭据 + 9 条 Job）；钉死插件版本（`services/jenkins/plugins.txt` name:version + `plugins.lock.md`）；官方 update center 源。
- **Jenkins SSH agent**（M1-T2）：`services/jenkins-agent`（无 docker.sock、普通用户 jenkins、固定 host key、探测工具链）+ `scripts/gen-jenkins-secrets.sh` 幂等生成 secrets/。
- **Job as Code + 挂载共享库**（M1-T5）：9 条 Job 由 `config/jenkins/jobs/*.groovy` 生成，流水线逻辑在 `ci/jenkins/pipelines/`，探测脚本 `ci/shared-library/bin/check-lan.sh` 挂载即生效。
- **LDAP 账号/组**（M1-T3）：`jenkins-ci`（口令 `Jenkins@2026`）、`jenkins-admins`（全权）、`jenkins-dev`（只读+构建）。
- **HomePage 卡片**（M1-T6）：服务状态 6→8（+Jenkins、Jenkins Agent），公网入口 4→5（+/jenkins/）。
- **文档**（M1-T7）：`docs/services/jenkins{,-agent}.md`、架构/启动顺序/镜像与供应链/安全基线同步，docs 登记册 +2。

### Changed
- **公网入口**（M1-T4）：`config/routes.yaml` 加 `/jenkins` `strip:false`，router `render()` 输出 `handle /jenkins/*`（保留前缀）而非 `handle_path`（剥前缀致 404）；Caddyfile 与 router PUBLIC_FIXED/STATUS_HTML 同步（7→9 服务）。
- **门禁/CI**（M1-T0.5）：`check-images.sh` SERVICES/BUILDABLE 加 jenkins 两项、pull_policy 放宽 `never|missing`；`build-images.yml` matrix 加两个镜像、分支触发 `feat/m1-jenkins`、fill-pending ref/base 动态化并把 CI digest 回填两个 compose；仓库变量 `PUSH_IMAGES=true`。
- **GitHub 清理**（M1-T0）：25 条历史 open issue 关单（#147 打 icebox）、5 个里程碑删除。

### Fixed（2026-11-25 二轮实测修复，T1~T9）
- **compose YAML**（T1）：`services/jenkins/compose.yml` 的 `environment` map/list 混用改统一 mapping，密钥两项改 `${VAR:-}`；补 `TZ`。
- **Job 全红根因**（T2/T3）：`check-lan.sh` 顶部 `DOMAIN:?` 断言改 `need_domain()` 按需解析（curl 探针不依赖 DOMAIN），case 认 `dns|dnsmasq`；agent compose 只读挂 `config/defaults.env` 兜底；`jenkins-agent` 分支加 uid/java/dig/DNS 真断言并纳入全服务检测（8 项）。
- **LDAP 固化**（T4）：账号/组从 `50-users.ldif` 拆到 `config/ldap/51-jenkins.ldif`（空卷首启按序导入）；`jenkins-admins` 含 jenkins-ci + zeek.zhao 两 member；给出已有卷 ldapadd 补齐命令（文档）。
- **匿名 403 白屏**（T5）：`jenkins.yaml` 加 `Hudson.Read:anonymous`（只 Overall/Read，不泄漏 Job），消除白底 "Authentication required"。
- **scheme 泄漏**（T6）：Caddyfile 与 router render 两处 `header_up X-Forwarded-Proto https`/`X-Forwarded-Host`，外链 `report-uri` 由 http 变 https。
- **深色主题**（T7）：`plugins.txt` + `plugins.lock.md` 钉 theme-manager/dark-theme（update-center 实解析），`jenkins.yaml` 顶层 `appearance.themeManager`（待镜像重建后生效）。
- **Job 冒烟**（T8）：新增 `scripts/jenkins-smoke.sh` + `make smoke` + `tests/bats/10_jenkins_smoke.bats`；反代 crumb 403 时用 `JENKINS_CONTAINER` 走容器内通道；日志落 `artifacts/jenkins-smoke/`（gitignore）。
- **收口**（T9）：`up.sh` 自动从 secrets 注入 SSH 密钥；`images.lock` 回填 jenkins 两行真实 imageId（零 PENDING）；`manifest.tsv` health_url 改容器内地址并标注为文档字段；`test-static.sh` 加 YAML 解析校验 + JENKINS_URL/PUBLIC_HOST 一致性断言；`JENKINS_URL` 由 PUBLIC_HOST 派生去重。

## [m0-v1.1] — 2026-11-24（已打 tag）

> 分支 `feat/m0-release`，tag `m0-v1.1` @ `abf5034`。本轮为展示层优化与清理，不动 `main`、不重建网络/数据卷。

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
