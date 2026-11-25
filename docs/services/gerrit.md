# Gerrit 服务手册（M2.1）

> 状态：已部署 + LDAP Web 登录验收通过（2026-11-26）| 分支 `feat/m2-gerrit-cgit-harbor` | 依据 OrgFlow M2 施工方案 §M2.1
> 评审流/建仓、端口互换仍为待初始化项（需管理员 HTTP password / 切公网入口），见 §6。

## 1. 职责

代码评审 + Git 服务。LDAP 认证（复用 M1 的 OpenLDAP），Web 走 Caddy `PUB_HTTP_GERRIT` 回环口（Funnel :8443 回源），SSH 发布宿主 `${P_GERRIT_SSH}` 供 tailnet 设备直连（Funnel 不转 TCP，公网不可达 SSH）。

## 2. 镜像与网络

- 镜像：`gerritcodereview/gerrit:3.9.0`（官方镜像，不走自建）。Docker Hub 在本环境被墙，改由 GitHub Actions（`.github/workflows/mirror-m2.yml`）在海外 runner 拉取官方镜像原样推 GHCR，本地经 `ghcr.nju.edu.cn` 代理下载；上游 manifest digest `sha256:25f02a98…` 钉在 `config/images.env` 的 `UPSTREAM_GERRIT`，同步 `tests/images.lock`。
- 固定 IP `.18`（`IP_GERRIT`），接 `orgflow-minimal_orgflow` 网络。
- 卷：`gerrit_git`（裸库，cgit 只读共享）、`gerrit_etc`（配置与 secure.config）。
- 配置：`services/gerrit/etc/gerrit.config.tmpl` → entrypoint 用 `out/urls.env` 渲染（canonicalWebUrl 等无字面域名），先备份 `.bak`。

## 3. 部署

```bash
# 前置：expand-memory（swap/cgroup）+ 卷预建（up.sh 幂等创建）
bash scripts/expand-memory.sh
make render                       # 生成 out/urls.env
docker volume create orgflow-minimal_gerrit_git
docker volume create orgflow-minimal_gerrit_etc
bash up.sh --only gerrit          # 单起
```

## 4. 初始化（一次性，人工）

1. ~~首个人类管理员手工加入管理员组~~：Gerrit 3.9 首个 LDAP 登录用户自动成为 `Administrators`（2026-11-26 实测 `zeek.zhao` 已在 Administrators），无需手工授权；如需 LDAP 组映射再补 `All-Projects` 权限。
2. `Global Capabilities` 给 `jenkins-ci` 授予 `Stream Events`（待确认）。
3. 建仓 `orgflow-devops`，`HEAD` 指向 `main`；初始内容从 GitHub 镜像导入（`git clone --mirror` + `git push --mirror`），不做空仓起步。**当前未建仓**：Gerrit REST 写操作（`/a/projects`）需管理员 HTTP password + Basic auth，纯 cookie 会话无效（实测 403）；待生成 HTTP password 后执行。

## 5. 验收（文档 §M2.1 判据）

| # | 判据 | 命令 | 状态（2026-11-26） |
|---|---|---|---|
| 0 | LDAP Web 登录 | 浏览器 `zeek.zhao` 登录，账号自动建号 | ✅ 通过（本轮修复） |
| 1 | Web 200 | `curl -sSI https://${PUBLIC_HOST}:8443/` | ✅ 200 |
| 2 | SSH ls-projects | `ssh -p 29418 <user>@<host> gerrit ls-projects` | ⏳ 端口可达，缺 SSH key |
| 3 | clone | `git clone https://${PUBLIC_HOST}:8443/All-Projects` | ✅ HTTP clone 成功；SSH clone 待 key |
| 4 | 评审流 | `git push HEAD:refs/for/main` 生成 Change | ⏳ 待建仓 + HTTP password |
| 5 | cgit 联动 | `https://${PUBLIC_HOST}/cgit/` 含项目列表 | ✅ 200；白名单后只列业务仓，不再泄露 All-Users.git |
| 6 | 端口互换 | `FUNNEL_PORT_GERRIT=10000` 后 render + funnel 重下发 | ⏳ 现网变更，待窗口 |

## 6. LDAP 认证关键配置（2026-11-26 根因修复）

M0 LDAP 安全基线是**匿名拒读**（`docs/services/ldap.md` / `tests/bats/S_ldap.bats`），不可放宽。Gerrit 3.9 LDAP realm 登录时先用服务账号 bind 搜索用户 DN，正确配置键是：

```ini
[ldap]
  supportAnonymous = false                          # 强制关闭默认匿名探测（关键）
  username = cn=admin,dc=orgflow,dc=local           # 服务账号（非 bindDN）
  password = <LDAP_PASSWORD>                        # 走占位符，entrypoint 运行时渲染
```

- **教训**：`bindDN`/`bindCredential` 是无效键，Gerrit 会忽略并继续用匿名 bind，登录页报 `Authentication unavailable at this time.`、LDAP 端见 `BIND dn=""` + `SRCH err=32`。Secure.config 里的小写 `bindcredential` 同样无效且可能缓存旧口令。
- 口令同源 `LDAP_PASSWORD`（与 Jenkins `managerPasswordSecret` 一致），由 `services/gerrit/compose.yml` 注入 `LDAP_ADMIN_PASSWORD`，entrypoint 用 **python3 `str.replace` 字面替换**渲染到卷内 `gerrit.config`（600/gerrit），**不进 git 源码/文档**。
  - 2026-11-26 复核修正：原用 `sed s|…|$PASS|g`，口令含 `|`/`&` 会截断/展开破坏配置；改 python3 字面替换后，实测 `p@ss|w&rd/\x` 原样保留、`${username}` 等 Gerrit 运行时变量不被误替换。值经环境变量传入不经 argv。
- 配置 `[container] user = gerrit`（官方镜像实际用户 gerrit/uid1000）；历史误写 `gerrit2`（debian 包用户名）已于复核后修正。
- 2026-11-26 实测：`zeek.zhao` / `change-me` Web 登录成功，账号 `Zeek Zhao <zeek.zhao@orgflow.local>` 自动创建且落入 `Administrators`。

## 7. 待办（未虚报）

- **判据 4 评审流 / 建仓**：需先为管理员生成 HTTP password（Gerrit REST `/a/` 写操作要求 Basic auth），建 `orgflow-devops` 仓并导入源码，再 `git push HEAD:refs/for/main` 验证 Change 生成。当前项目列表仅 `All-Projects`/`All-Users`。
- **判据 2/3 SSH 路径**：SSH 29418 端口可达，但需为账号配置 SSH public key 后才能 `ls-projects` / SSH clone；HTTP clone（`https://…:8443/All-Projects`）已实测成功。
- **判据 6 端口互换**：改 `FUNNEL_PORT_GERRIT` 会切换公网入口，属现网变更，待窗口执行并验证 URL 跟随/旧端口失效。
- 物理内存约 5.x GiB，Gerrit JVM 常驻较大，依赖 8 GiB swap；内存紧张时可能明显换页。

## 8. 安全与策略（2026-11-26 复核）

本节点来自验收方的差距清单复核，逐条记录处理意见：

| 风险项 | 现状 | 处理 |
|---|---|---|
| 匿名项目列表可读 | `https://<host>:8443/projects/?d` 匿名可见项目名，与"LDAP 匿名拒读"口径似乎矛盾 | **既定公开策略**：cgit 本身是公开只读视图，项目名非敏感；LDAP 匿名拒读针对用户条目（含 SSH key/邮箱），二者对象不同。写进本文明确，非缺陷。若要收回，调 `All-Projects` 的 `refs/*` READ 权限给 `Anonymous Users`（会影响 cgit 公开视图，需同步评估）。 |
| SSH 29418 绑 0.0.0.0 | compose `ports` 发布 `${P}:${P}`，宿主若直连公网则暴露 Gerrit SSH | **当前由 Funnel 不转 TCP + 宿主防火墙兜底**：公网只走 :8443 HTTP，29418 仅 tailnet 可达。加固建议（未改，避免破坏 SSH 判据）：把 compose ports 改为绑定 tailscale0 的具体 IP（`100.x.y.z:29418:29418`），或在宿主加 `iptables` 仅放行 tailnet 段。属现网网络变更，待窗口。 |
| 口令 sed 渲染 | 见 §6，已修 | ✅ 本轮改 python3 字面替换 |
| `[container] user = gerrit2` | 与镜像实际用户不符 | ✅ 本轮改 `gerrit` |
| cgit `scan-path` 全目录 | 见 `docs/services/cgit.md`，已修 | ✅ 本轮改 `project-root` + 白名单 |
| 内存 / Harbor 选型 | 物理约 5.7 GiB，靠 cgroup 12G + 8G swap 撑；Harbor 官方 6 容器栈峰值会重度换页 | **M2.2 选型建议**：优先 `registry:2`（单容器，资源可控）；若必须 Harbor 完整栈，分阶段先 `core+registry+db`，逐容器加内存预算。属 M2.2 范围，未在本轮实施。 |
