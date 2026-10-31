# [03] 参数化 deploy / backup Job（JJB + 共享库）

- **Issue**：#3
- **PR**：#8
- **分支**：`feat/3-param-jobs`
- **类型**：回溯重建（原文是一段话的派单 prompt，验收口径按当前仓库状态重写）
- **依赖**：#2（Job 要用的 Credentials 由认证栈提供）
- **token 预算**：约 12 万 token

## 目标

把 `deploy-service` / `backup-service` 从**占位 YAML** 变成真正可跑的参数化 Job：

- Job 定义能渲染（JJB 不报错），能推到 Jenkins
- 共享库被 Jenkins 认到（`@Library('orgflow-shared')` 不报 `No such library`）
- Pipeline 里有 `checkout`，`dir()` 指向的目录真实存在
- `DRY_RUN` 真的生效（不是摆设）
- 敏感项走 Jenkins Credentials，**不出现在 Job 参数和日志里**

## 背景与取证

原 Job 定义只是壳子，六处硬伤（**开工前逐条确认，别重新发现一遍**）：

| # | 硬伤 | 后果 |
|---|---|---|
| 1 | `config/jenkins_jobs.ini` 不存在 | `scripts/deploy.sh --push-jobs` 必然失败 |
| 2 | `config/jenkins.yaml` 没注册 `globalLibraries` | `@Library('orgflow-shared')` → "No such library" |
| 3 | Job 没有 checkout，pipeline 却 `dir('orgflow-devops')` | 目录不存在，必挂 |
| 4 | `DRY_RUN` 声明了但没传给共享库 | 是摆设 |
| 5 | 没有任何 `withCredentials` | 敏感项无来源 |
| 6 | `jenkins-jobs` 没有可执行环境 | 宿主机没有、无 dev 容器 |

JJB 实测踩到的四个坑（**都已修，不要再踩**）：

| 坑 | 正确做法 |
|---|---|
| inline Pipeline 字段名 | 必须是 `dsl`；用 `pipeline:` 渲染不出 `<script>`，Job 是**空的**（不报错） |
| 布尔参数类型 | 是 `bool`，不是 `boolean` |
| Groovy 花括号 | JJB 对 inline string 做**一次** `.format()` → `{` 必须预先转义成 `{{`，`}` → `}}` |
| Pipeline 顶层 `scm` | JJB **忽略**它 → 必须在 DSL 里显式 `checkout(scm)`，并带 `github-token`（仓库是 private） |

## 范围

**改**

| 文件 | 改法 |
|---|---|
| `config/jenkins.yaml` | 注册 `globalLibraries(orgflow-shared)`；补 5 个 Credentials：`github-token` / `ldap-admin-password` / `oauth2-client-secret` / `oauth2-cookie-secret` |
| `config/job_definitions/deploy/deploy-service.yaml` | 参数白名单；inline pipeline 字段名改 `dsl`；花括号转义；显式 `checkout(scm)` |
| `config/job_definitions/backup/backup-service.yaml` | 同上；删掉假装支持的 Nexus 目标 |
| `shared-library/vars/deployService.groovy` / `backupService.groovy` | 去 `dir()`；`withEnv` 传参；`withCredentials` + `set +x`；`dryRun` 早退；入参白名单校验 |
| `scripts/deploy.sh` / `backup.sh` | 支持 `--service`；backup 不再假装支持 Nexus |
| `Makefile` | 新增 `jobs` / `jobs-test`（免 `.env`）/ `test-groovy`（groovy 缺失自动跳过） |
| `.env.example` / `.gitignore` / `docs/M0-最小核心.md` | 补变量、忽略 `.jjb/`、写前置条件与参数支持边界 |

**新增**

| 文件 | 内容 |
|---|---|
| `tools/jjb/Dockerfile` | `python:3.11-slim` + `jenkins-job-builder`，显式 `setuptools<81` |
| `config/jenkins_jobs.ini.tpl` | JJB 连接模板，占位符不落密码 |
| `scripts/gen-jjb-conf.sh` | 从 `.env` 渲染到 `.jjb/`（目录 0700 / 文件 0600）；**不执行** `.env`；转义 ConfigParser 的 `%`；`--placeholder` 供纯本地校验 |
| `scripts/test_jobs.py` | 纯逻辑测试：参数白名单、环境变量注入、渲染产物结构 |
| `shared-library/test/stepsTest.groovy` | 用 GroovyShell + metaClass 打桩，无外部 jar |

**删**

| 文件 | 理由 |
|---|---|
| `backup-service` 里的 Nexus 目标参数 | 脚本根本没实现，留着会让使用者以为能用 |

## 验收

- [ ] `python3 scripts/test_jobs.py` → 退出码 `0`
- [ ] `make jobs-test` → 退出码 `0`
- [ ] `ls .jjb/rendered/*.xml \| wc -l` → `2`（deploy-service / backup-service）
- [ ] `grep -l 'DRY_RUN' .jjb/rendered/*.xml \| wc -l` → `2`
- [ ] `grep -l 'withCredentials' .jjb/rendered/*.xml \| wc -l` → ≥ `1`
- [ ] `grep -l 'checkout' .jjb/rendered/*.xml \| wc -l` → `2`
- [ ] `grep -l 'github-token' .jjb/rendered/*.xml \| wc -l` → `2`
- [ ] `bash -n scripts/gen-jjb-conf.sh` → 退出码 `0`
- [ ] `bash scripts/gen-jjb-conf.sh --placeholder` → 退出码 `0`，`.jjb/` 权限 `700`、文件 `600`
- [ ] `make test-groovy` → 通过或明确打印「groovy 未安装，跳过」（**不得静默跳过**）
- [ ] 明文密钥扫描：`grep -rniE '(password|secret|token)\s*[:=]\s*[A-Za-z0-9]{8,}' config shared-library \| grep -v '\${' ` → 无输出
- [ ] 反证：把某个 Groovy 里的 `{` 改回单括号 → `make jobs-test` **必须报 `KeyError` 或 format 错误**；改回 `{{` 复绿
- [ ] 反证：把 inline pipeline 的 `dsl:` 改成 `pipeline:` → `.jjb/rendered/` 里对应 XML 的 `grep -c '<script>'` 变 `0`（Job 是空的，且**不报错**——这就是它危险的地方）

## 禁止事项

- 不得在 `config/jenkins_jobs.ini.tpl` 里写真实密码：它入库，只放占位符
- 不得让 `gen-jjb-conf.sh` `source .env`：`.env` 里的值可能含 `$` 和 `%`，执行会被展开/破坏
- 不得把凭据作为 Job 参数暴露（参数会进构建历史）：一律走 `withCredentials`
- 不得在共享库里 `set -x`：会打印凭据
- 不得为了「能推上去」而放宽 Credentials 的 ID 校验
- 不得自行合并 PR

## 依赖与前置

- [ ] `docker compose version` → `v2.x`（`jjb` 服务在 `profiles: ["tools"]`，不影响 `up -d`）
- [ ] `python3 -c "import yaml"` → `0`
- [ ] 在线推送 Job 需要真实 PAT + Jenkins 已起 + 有 `orgflow-docker` 标签的 agent；
      **这些不具备时不要硬推**，把 `make jobs-test`（离线渲染）跑绿即可，并在 PR 里写明未验证

## 交付物

- [ ] 分支 `feat/3-param-jobs`
- [ ] PR 正文含：做了什么 / **JJB 四个坑的实测记录** / 验收实测表 / 未验证项 / 参数支持边界
- [ ] 参数支持边界写进 `docs/M0-最小核心.md`（`VERSION` 只对 Jenkins/Nexus 生效、
      `DOMAIN` 非空报错、`BACKUP_TARGET` 仅 `local`、`ENV` 只选文件不建隔离环境）

## 当年实测（PR #8 记录）

| 项 | 结果 |
|---|---|
| `test_render.py` / `test_bootstrap.py` / `test_jobs.py` | 10/10 / 6/6 / 11/11 |
| `make jobs-test` | 渲染 2 个 Job，无 KeyError / 无 format 报错 |
| 产物含 `DRY_RUN` / `withCredentials` / `github-token` / `checkout` | 全部命中 |
| `make render` | 仍 5 条路由 |
| 服务健康 | ldap / dex / oauth2-proxy 仍 healthy |
| 明文密钥扫描 | 干净 |

## 未验证（当年就没验证，别当成已验证）

**在线推送 Job 到 Jenkins 并实跑**未验证。依赖：真实 PAT、5 个 Credentials、
Pipeline 相关插件、`orgflow-docker` 标签的 agent。

## 与本卡的偏离

- 当年的 `PORT` / `DOMAIN` 两个参数已在 #18 删除（ADR-13 域名路由）：
  网关端口统一走 `GATEWAY_HTTP_PORT` / `GATEWAY_HTTPS_PORT`，域名走 `routes.yaml`。
  现在传 `port:` / `domain:` 会**明确报废弃错**，不会静默忽略
