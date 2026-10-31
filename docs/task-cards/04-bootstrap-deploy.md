# [04] Jenkins 自举一键部署（Makefile / deploy.sh）

- **Issue**：#4
- **PR**：#9
- **分支**：`feat/4-bootstrap-deploy`
- **类型**：回溯重建（原文是一段话的派单 prompt，验收口径按当前仓库状态重写）
- **依赖**：#2（受保护站点已存在）、#3（Job 定义）
- **token 预算**：约 10 万 token

## 目标

干净机器上 `make deploy` 一条命令起全套底座，并且**真的等到健康才报成功**。

- `.env` 缺失时自举生成（随机密钥，只提示存放位置，不 echo 密码）
- 分批拉起，每批等 healthy 再进下一批
- 失败时能定位到**具体服务**，并打印脱敏后的日志尾部
- 另有 `make doctor`：**只读**自检，不起容器、不改任何东西

## 背景与取证

**核心陷阱（这条最重要）**：#2 给受保护站点加了 `forward_auth` 之后，未登录访问立即返回 **302**。
旧 `deploy.sh` 用 `curl -fsS .../jenkins/login` 轮询 —— **`-f` 只对 4xx/5xx 失败，302 被当成成功**，
于是 Jenkins 还没起来就打印 "Jenkins ready"。

结论：**就绪判定不能靠 HTTP 状态码**。改为 `docker inspect` 的 `Health.Status`，
端点自检移到健康闸门**之后**。

| 事实 | 值 / 结论 | 怎么来的 |
|---|---|---|
| `curl -f` 对 3xx 不失败 | 302 被视为成功 | `curl -fsS -o /dev/null -w '%{http_code}' <受保护URL>` → `302`，退出码 0 |
| `docker inspect` 的健康状态是 `Health.Status` | `starting` / `healthy` / `unhealthy` | `docker inspect -f '{{.State.Health.Status}}' of-jenkins` |
| `jenkins/jenkins:lts-jdk17` 首次启动要 60–120s | 期间 `Health.Status` 为 `starting` | 冷启动实测 |
| `compose config` 的报错正文可能含密钥 | 失败诊断里**不能**直接输出 | `docker compose config` 报错会回显变量值 |

## 范围

**改**

| 文件 | 改法 |
|---|---|
| `scripts/deploy.sh` | 重写：`.env` 自举 + 分批拉起 + `Health.Status` 闸门 + 失败诊断（脱敏）+ 闸门后端点自检 |
| `docker-compose.yml` | 给 `jenkins` / `caddy` / `router` / `nexus` 补 healthcheck |
| `services/router/render.py` | 新增最小 `/healthz`（`http.server`，零依赖）+ `--health-port` |
| `services/router/reload.sh` | 配合 healthz 端口 |
| `Makefile` | 新增 `doctor`；`deploy` 走新流程 |
| `docs/M0-最小核心.md` | 新增「干净环境自举」一节 + **302 语义说明** |

**新增**

| 文件 | 内容 |
|---|---|
| `scripts/doctor.py` | 只读自检：工具 / daemon / `.env` / 端口 / 镜像 / 磁盘，共 18 项 |
| `scripts/test_deploy.py` | 参数与流程回归（含「doctor 必须只读」的断言） |

## 验收

- [ ] `python3 scripts/test_deploy.py` → 退出码 `0`
- [ ] `make doctor` → 退出码 `0`，18 项检查全 OK
- [ ] **只读证明**：`make doctor` 前后 `docker ps --format '{{.Names}}'` 输出**完全相同**（不起容器）
- [ ] `make doctor` 前后 `git status --porcelain` 为空（不改文件）
- [ ] `bash -n scripts/deploy.sh` → 退出码 `0`
- [ ] `docker compose config -q` → 退出码 `0`
- [ ] `make deploy`（幂等重跑）→ 退出码 `0`，末尾打印全部服务 `healthy`
- [ ] 反证：故意把一个服务的 `image:` 改成不存在的 tag → `make deploy` **非 0 退出**，
      且输出里能看出**是哪个服务**，并且 `grep -c 'PASSWORD\|SECRET\|TOKEN=' 输出` → `0`（已脱敏）
- [ ] 反证：`make deploy` 的输出里 **不得**出现 `Jenkins ready` 这类基于 302 的假成功文案；
      可用 `grep -c 'Jenkins ready'` → `0` 断言旧逻辑已删干净

## 禁止事项

- 不得用 HTTP 状态码判断服务就绪：受保护站点的 302 会伪装成成功
- 不得在失败诊断里输出 `docker compose config` 的报错正文：可能含密钥
- 不得 echo 自动生成的密码：只打印「已写入 `.env`，位置是 …」
- 不得让 `make doctor` 起容器或写文件：它是排障第一步，必须无副作用
- 不得自行合并 PR

## 依赖与前置

- [ ] `docker compose version` → `v2.x`
- [ ] 可用磁盘 ≥ 5 GB（镜像 + 卷）
- [ ] 端口 `80` / `443` / `8081` / `5556` / `4180` 未被占用（或已在 `.env` 改）

## 交付物

- [ ] 分支 `feat/4-bootstrap-deploy`
- [ ] PR 正文含：做了什么 / **302 语义这个回归的说明** / 验收实测表 / 环境说明
- [ ] 「302 不等于就绪」写进 `docs/M0-最小核心.md`，不能只写在 PR 里

## 当年实测（PR #9 记录）

| 项 | 结果 |
|---|---|
| 测试总数 | 40 项全过（router 14 / bootstrap 6 / jobs 11 / deploy 9） |
| `make doctor` | 只读，18 项检查全 OK，不起容器 |
| `make deploy`（幂等重跑） | rc=0，8 个服务全部 healthy |
| `/auth/ping` | 200 |
| `/jenkins` | 302（受保护，**非就绪信号**） |
| 错误镜像场景 | 能定位到具体服务并输出脱敏日志 |

## 环境说明（当年）

`jenkins/jenkins:lts-jdk17` 当年从 Docker Hub 反复 `connection reset`，
最终经 daemon 已配置的镜像站取到同一 digest 并打回原始 tag。
这是**环境网络问题**，不影响仓库内容——但现在已改为经 GHCR 镜像（见 #12），不再依赖 Docker Hub。

## 与本卡的偏离

- 当年就绪判定用的是 `docker inspect` 的 `Health.Status`；ADR-13 之后站点变成域名，
  端点自检改为 `https://<sub>.<domain>:<https端口>`，健康闸门逻辑不变
- 当年 8 个服务，现在 9 个（多了 `dnsmasq`）
