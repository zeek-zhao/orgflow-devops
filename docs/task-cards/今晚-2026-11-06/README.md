# 今晚批次（2026-11-06）任务卡总览 · 派工入口

> **派工批次**：今晚 2026-11-06（用户 22:36 指令）。
> **本目录只有需求与验收，不含实现代码。** 另一个 AI 读 GitHub 上的这些卡片与挂起的
> Issue，自行建 PR 解决问题；派单方不代写实现。
> 全部归入 **M0**；**M1 #60 冻结**，到 M0 全绿且用户人工确认之后才解锁。
> Issue 是需求真本，卡片与 Issue 冲突时**以 Issue 为准**。

## 用户指令（逐字）

> jenkins 要有 Pipeline Overview，安装 dark-theme 插件，设置默认主题为 dark ，
> Gerrit Trigger 插件，TAP Plugin ， SSH Agent ，docker ，Build Monitor View，，
> Throttle Concurrent Builds Plug-in，Timestamper，Workspace Cleanup Plugin，
> 禁止jenkins及其插件的自动更新，认证使用ldap。然后接开始对于任务进行分类，
> 放在不同的面板上，根据部署呀或者备份啊，或者是根据服务，然后放在不同的面板上
> 然后增加子节点的不同接入方式的交补包含SSH预接入，然后SH单核介入。
> 然后通过an python的部署软件那个什么玩意儿，然后去远程部署。
> nexus 配置docker和Python服务器和代理，然后并且测试拉推送没问题。
> issues/65 关闭
> 继续该建卡的建卡，该建单的建单，然后现在提的需求都归入M0，M0全部做完之后，
> 然后在人工确认完之后，然后再开其他的任务。今天晚上会用AI把这些所有的任务全部做完。
> 如果有一些需要人工确认的，先前置出来，我先确认。

## 已裁决的口径（两轮 grill-me 收敛，不要再问用户）

| # | 决策 | 用户裁决 |
|---|---|---|
| 1 | 插件镜像交付 | **改源码后等 CI 构建**；先修 3 处 CI 缺陷，单独打 `24.04-v3`，**不覆盖现网 `24.04-v1`** |
| 2 | Gerrit / 远程部署缺真实端点 | **只装插件、留配置占位，不虚构成功** |
| 3 | Jenkins 认证 | **切 LDAP realm + 组授权 + admin 兜底**；兜底实现为「组授权 + realm 回滚预案」 |
| 4 | 子节点与远程部署 | **Ansible + 两种 SSH 节点**；「单核」按 `numExecutors: 1` 理解 |
| 5 | Nexus 暴露 | **新增 `docker.`/`pypi.` 两条子域走 Caddy 443**，宿主不直开端口 |
| 6 | #114 备份基线 | **加 uid 一致性硬门禁**，不删旧包、不新建备份（遵守「不需要备份」裁决） |
| 7 | 面板维度 | 按动作 + 按服务**双维度 ListView**（派单方默认，用户未反驳） |
| 8 | 插件歧义 | Pipeline Overview = `pipeline-graph-view` + `pipeline-stage-view`；「docker」= `docker-plugin` + `docker-workflow`；装回 Timestamper 后恢复 `timestamps()`；「禁止自动更新」= 镜像 digest 钉死 + 插件逐项钉版本 + 静态闸门 |
| 9 | 建单粒度 | 全新需求簇才建单，同源需求归并到既有 Issue，**不建重复单** |
| 10 | M0 收口 | M0 全绿 + 用户人工确认后才解锁 M1 #60 |

## 单据对照（GitHub 真本）

| 任务卡 | Issue | 标题 | 状态 |
|---|---|---|---|
| `TC-N-01` | **#115** | Jenkins 插件集、dark 默认主题、禁止自动更新与 CI 镜像链路修复 | 新建 · Todo |
| `TC-N-02` | **#87** | Jenkins 直连 LDAP + 组授权 + realm 回滚预案（归并，不新建） | 既有 · Todo |
| `TC-N-03` | **#116** | Jenkins 视图分类、SSH 双节点接入与 Ansible 远程部署占位 | 新建 · Todo |
| `TC-N-04` | **#117** | Nexus Docker / PyPI 仓库与拉推实测 | 新建 · Todo |
| `TC-N-05` | **#114** | 备份基线 uid 一致性硬门禁 | 既有 · Todo |
| `TC-N-06` | **#86/#88/#89/#104** | M0 全量收口与人工确认清单 | 既有 · Todo |
| —— | **#65** | 局域网 oauth2 登录人工验收 | **已关闭**（用户 22:36 指令） |
| —— | **#60** | 定义 M1 范围与卡片拆分 | **冻结**，非本批次 |

M0 里程碑在本批次开始时仍有 6 个 open：`#86 / #87 / #88 / #89 / #104 / #114`，
加新建的 `#115 / #116 / #117`，**今晚收口目标是 M0 open 归零**。

## 开工前已取证的事实（不必重查，可直接引用）

| 事实 | 值 |
|---|---|
| Jenkins 内核 | **2.580.2**（`docker exec of-jenkins java -jar /usr/share/jenkins/jenkins.war --version`） |
| 现网 Jenkins 镜像 | `ghcr.io/zeek-zhao/orgflow-devops/jenkins:24.04-v1@sha256:2e211bf4…` |
| 运行时插件 | **65 个 active**，**没有 ldap**，也没有本批次任何一个新插件 |
| 两套构建上下文 | `tools/jenkins/`（7 插件旧版，**CI 在用**）vs `services/jenkins/`（8 插件新版，**compose 在用**） |
| CI 缺陷 1 | `.github/scripts/select-images.sh` 的 `jenkins` context 指 `tools/jenkins` |
| CI 缺陷 2 | `.github/workflows/images.yml` 的 `paths` 不含 `services/jenkins/**` → 改插件清单不触发构建 |
| CI 缺陷 3 | `docker/metadata-action` tag 硬编码 `24.04-v1`（现网正在用）→ 构建会覆盖它 |
| `tests/images.lock` | `jenkins` 行是 `待构建后回填` 文字占位 → `make check-pins` **RC=2**（#104 第 1 项） |
| Actions 可用性 | 最近 5 次 `images.yml` run 全部 success；`permissions: packages: write` 已声明 |
| 出网 | 213 可达 update center(301→需 `-L`) / plugins.jenkins.io(200) / GHCR(401 正常)；**拉不到 Docker Hub** |
| 插件 ID | 12 个目标 ID 逐一查 `plugins.jenkins.io/<id>/` 全部 200 |
| **兼容坑** | `pipeline-graph-view` 最新 `1101.v86fd4564c864` 要求 core **2.589 > 2.580.2**；应钉 **`1053.v9df19e6ceed2`**（requiredCore 2.555.3，为 2.580.2 下最新可用）。其余 19 项 requiredCore ≤ 2.555.3 |
| JCasC 现实 | `config/jenkins.yaml` 只有 111 行、`securityRealm: local`、**只能有一个 realm**；切 ldap 后本地 `admin/密码` 账号消失 |
| 403 根因 | `securityRealm: local` 不消费 `X-Auth-Request-User`；OIDC 链走完落到 Jenkins 仍 403 |
| 线上 LDAP | 18:20 删卷重建后 **33 条 / 10 个 `uid=` DN / uidNumber 1000–1009 / displayName 10/10 / 21 处 memberUid 无悬空 / 10 账号 bind 全过**；`svc-platform-admin` 在 `jenkins-admin` 组 |
| 视图与节点 | 只有 `all` 一个视图、16 个 Job（仅 3 个有过构建）；节点只有 `Built-In Node` + `orgflow-docker`（SSH launcher，2 executors，host key `manuallyProvided`） |
| 凭据 | `secrets/` 只有 agent SSH key 对；`.env` 无 GERRIT / ANSIBLE / PYPI 变量 |
| Nexus | `sonatype/nexus3:3.92.2`；现有 **7 个仓库全是 maven2/nuget**；`8081/tcp` **未映射宿主**，容器 IP `172.31.0.21`，靠 Caddy 同网络 `--network-alias nexus` 反代 |
| 路由 | `config/routes.yaml` 现有 7 个子域：`jenkins / nexus / ldapadmin / dex / auth / home / ca`；`docs` 无容器、无路由、访问 `000` |
| 备份风险 | `out/backups/` 里 **6 个 `ldap-*.tgz` 仍是旧 uid**；`verify-ldap` 会真恢复并静默回滚线上。**门禁生效前不要跑它** |
| 仓库约定 | `docs/task-cards/34-session-handoff.md` 明确写「本仓不涉及 gerrit」「gerrit-trigger 判活与本仓无关」 |

## 派工顺序

1. **TC-N-01 先做**：CI 链路修好 → 合入 main → `images.yml` 被 push 触发 → 产出 `24.04-v3` 真实 digest。
   这一步没完成，#115/#87/#116 的插件与认证都无法上线。
2. TC-N-02 / TC-N-03 / TC-N-04 / TC-N-05 可并行（互不改同一批文件）。
3. **TC-N-06 最后**：等 digest 回填、部署、真跑验收后，逐单贴证据关单，产出人工确认清单。

## 人工确认项（必须前置给用户，自动化不能替）

1. dark 主题、7 个面板、Pipeline Overview 在浏览器里的实际观感；
2. LDAP 账号登录 Jenkins / Nexus / phpLDAPadmin 的真实体验（含**非组成员被拒**）；
3. Docker / PyPI 从**另一台局域网机器**拉推是否可用（新增 2 条子域后 hosts 条数变化，需重新做跨机浏览器验收）；
4. 是否认可「Gerrit / 远程部署只留占位」作为 M0 收口边界；
5. 是否认可 `verify-ldap` 现在会**明确拒绝**旧包（而不是静默回滚）；
6. **M0 是否宣布收口** —— 只有这一条确认后才解锁 M1 #60。

## 派工铁律（每张卡都适用）

- 不改 `.env`（`deploy.sh` 有「已有 .env 绝不修改」约定）；凭据只用环境变量 / `withCredentials`。
- 不伪造通过：所有验收必须真跑并贴原始输出、run id、HTTP 码；不许写「应该可以」「预计通过」。
- 不为过测试放宽判据；发现夹具不匹配就**修夹具**，不是删断言。
- 不自行合并 PR；派工分支由派单方 `gh pr merge --rebase` 合并（禁止 squash）。
- author 恒为 `zeek.zhao <zeek.zhao@foxmail.com>`；commit message 含反引号时落文件用 `-F`。
- 不用 `--no-verify` 绕过 pre-push；rebase 后的既有分支换新分支名推送。
- `pre-push` 钩子在既有分支上会误扫 GitHub rebase 的 committer —— 换全新分支名，不是绕钩子。
- 每条关单评论必须附真实证据；**需要人工浏览器验收的项目不许自行关单**。
