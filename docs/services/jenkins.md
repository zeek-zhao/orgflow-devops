# jenkins

CI 流水线。跑 `deploy-service` / `backup-service` / `restore-service` 三个参数化 Job。

## 用途与端口

| 项 | 值 |
|---|---|
| 容器名 | `of-jenkins` |
| 固定 IP | `172.31.0.20` |
| 端口 | `8080`（容器内，**不发布到宿主**） |
| 镜像 | **自建** `ghcr.io/zeek-zhao/orgflow-devops/jenkins:24.04-v1`（`FROM jenkins/jenkins:lts-jdk21` + `services/jenkins/plugins.txt`）。#90 新插件镜像 tag 为 `24.04-v2`，digest 待构建后回填，见「digest 锁定状态」 |
| 构建上下文 | `services/jenkins/`（#90 起）—— compose 里是 `build:` 而不是 `image:` |
| 卷 | `jenkins_home` → `/var/jenkins_home` |

> 为什么自建：官方镜像**一个插件都不带**，而 `deploy-service` 这些是 pipeline job，
> 没有 `workflow-aggregator` 根本跑不起来；另外 213 拉不到 Docker Hub，只能在 CI 构建后推 GHCR。
> 底座 `jenkins/jenkins:lts-jdk21` 由 GitHub runner 拉（runner 有外网），不需要进 mirror。
> 默认插件清单见 `services/jenkins/plugins.txt`（#90 新增 `ldap` 等），由 Dockerfile 里的
> `jenkins-plugin-cli --plugin-file` 装进 `/usr/share/jenkins/ref/plugins`。

**不发布宿主端口**是有意的：所有访问都必须经过网关，否则 `forward_auth` 可以被绕过。
要直连只能在容器网络里：

```bash
docker compose exec -T jenkins curl -sS -o /dev/null -w '%{http_code}\n' http://localhost:8080/login
```

## 入口与依赖

- **入口**：`https://jenkins.org-devops.com`，`routes.yaml` 里 `auth: true`
- **登录链路**：浏览器 → Caddy（`forward_auth`）→ oauth2-proxy → Dex → LDAP
- **依赖谁**：`dnsmasq`、`dex`（登录）、`oauth2-proxy`（会话校验）
- **被谁依赖**：无。但 Jenkins 挂了不影响网关和其它服务

未登录访问返回 **302** 到 `https://auth.org-devops.com/oauth2/start`。
**302 不是就绪信号**——`deploy.sh` 曾经用 `curl -f` 轮询这个端点，因为 `-f` 对 3xx 不失败，
Jenkins 还没起来就打印了 "ready"。现在就绪判定看 `docker inspect` 的 `Health.Status`。

## 部署与配置

```bash
make deploy            # 全套起，分批等 healthy
docker compose up -d jenkins
```

**改了 `services/jenkins/plugins.txt` 或 `Dockerfile` 之后**：等 main 的 Images 工作流跑完
（只构建 `jenkins` 一个），再 `make images-pin` 回写 `docker-compose.ghcr.yml` 的 digest，
然后重新 deploy。**跳过这一步，213 上跑的还是旧镜像**，而 `make deploy` 不会报任何错。

> ⚠️ #90 本轮把 compose 的构建上下文切到了 `services/jenkins/`，但 CI 裁剪映射
> （`images.yml` / `.github/scripts/select-images.sh` / `scripts/test_ci.py` /
> `tests/bats/00_stack.bats`）仍指向旧的 `tools/jenkins/`，**派单方合并时须同步**，
> 否则改 `services/jenkins/` 不会触发 Images 工作流。详见 [M0 镜像与 CI](../M0-镜像与CI.md) 的「#90」节。

**Job 跑在哪**：不在 Jenkins 容器里，在独立的 **`jenkins-agent`** 容器（SSH 接入，
挂宿主 `/var/run/docker.sock`）。所以 job 里 `docker` 能用，Jenkins 容器里不能。
agent 的三个大坑（组权限、host key、initgroups）见 [jenkins-agent](jenkins-agent.md)。

| 文件 | 作用 |
|---|---|
| `config/jenkins.yaml` | JCasC：管理员、全局库、Credentials |
| `config/job_definitions/` | JJB 的 Job 定义（deploy / backup / restore） |
| `shared-library/` | 共享库 `orgflow-shared` |
| `jenkins_home` 卷 | 全部状态。**备份只保这个卷** |

Job 定义不在这里手改再点界面——用 JJB 推：

```bash
make jobs        # 需要真实 .env 和可达的 Jenkins
make jobs-test   # 离线渲染，只验证定义能不能生成
```

## 默认插件清单（#90）

`services/jenkins/plugins.txt` 是纯列表（不写注释、不钉版本），Dockerfile 用
`jenkins-plugin-cli --plugin-file` 安装：

| 插件 | 作用 |
|---|---|
| `workflow-aggregator` | 三个 job 都是 pipeline，缺了 job 定义都解析不了 |
| `git` | 拉共享库 `orgflow-shared` 与业务仓库 |
| `credentials` | JCasC 声明的凭据 |
| `credentials-binding` | pipeline 里 `withCredentials` |
| `plain-credentials` | `ldap-admin-password` 等 Secret text 凭据 |
| `ssh-slaves` | SSH 接入 agent 容器 |
| `ldap` | #90 新增：LDAP 登录 / 组解析 |
| `configuration-as-code` | 让 `config/jenkins.yaml` 生效 |

静态自检 `make check-jenkins-image`（挂进 `make test`）保证 5 项必装插件
（`workflow-aggregator` / `git` / `credentials` / `ldap` / `configuration-as-code`）
各出现一次、且 Dockerfile 仍用 `jenkins-plugin-cli`。反证：删掉
`workflow-aggregator` 后 `make test` 必须红，恢复后复绿。

## digest 锁定状态（#90，本轮未构建）

本轮只提交源码，**不构建、不推送镜像**。新插件镜像按「新增 tag」登记为 `24.04-v2`，
但真实 digest 尚未产生，`tests/images.lock` 的 jenkins 行写成明确的「待构建后回填」
文字占位，**不是编造的 sha256**；`docker-compose.ghcr.yml` 仍指向已发布、未改动的
`24.04-v1@sha256:2e211...`（不含 #90 新增插件）。

两道闸门防止带占位上线：`tests/images.sh ensure` 要求 `@sha256:[a-f0-9]{64}`；
`make check-pins` 挂在 `USE_GHCR=1` 的 `up` / `deploy` 前置，命中占位即失败。
`USE_GHCR=1` 时 compose 必须 `--no-build`（override 的 `image` 是 digest 引用）。

**未验证**：容器内插件清单（`jenkins-plugin-cli --list`）、24.04-v2 的 digest 与
GHCR 可复现性——都要等构建轮补齐。回填后去掉占位，才允许 `USE_GHCR=1 make deploy`。

## 关键环境变量

| 变量 | 作用 | 默认 |
|---|---|---|
| `JENKINS_ADMIN_ID` | 初始管理员账号 | `admin` |
| `JENKINS_ADMIN_PASSWORD` | 初始管理员密码，**必填** | 无 |
| `JENKINS_URL` | 对外地址，写进邮件和回调 | `https://jenkins.<domain>/` |
| `GITHUB_USER` | 拉 private 仓库用的账号 | `zeek-zhao` |
| `GITHUB_TOKEN` | 该账号的 PAT，**必填** | 无 |
| `OAUTH2_CLIENT_SECRET` | Dex 的 client secret | 无 |
| `LDAP_ADMIN_PASSWORD` | 建 Job 时读写 LDAP 用 | 无 |
| `JAVA_OPTS` | JVM 参数 | `-Djenkins.install.runSetupWizard=false` |
| `JENKINS_AGENT_SSH_PRIVATE_KEY` | agent 的 SSH 私钥，写进 JCasC 的 `directEntry` | 由 `deploy.sh` 从 `secrets/agent_ssh_key` 读出并 `export` |
| `JENKINS_AGENT_HOST_KEY` | agent 的 sshd host key 公钥。**必须切成「算法 base64」两列** —— `.pub` 第三列是注释，带着会让 `parseKey` 失败 | 由 `deploy.sh` 从 `secrets/agent_host_key.pub` 切两列后 `export` |

> 最后两个**不在 `.env` 里**。它们是 `deploy.sh` / harness / `Makefile` 探测后
> `export` 的裸变量，compose 里写成不带 `=` 的 `- JENKINS_AGENT_HOST_KEY` 透传。
> 私钥和 host key 都放在 `secrets/`（不进 git），由 `scripts/gen-agent-key.sh` 幂等生成。

`.env` 里的真实值不要写进任何文档或 Job 定义——Job 侧一律走 Credentials（`github-token` 等）。

## 排查步骤

**1. 容器健康吗**

```bash
docker inspect -f '{{.State.Health.Status}}' of-jenkins
```

首次启动要 60–120 秒。`starting` 卡超过 5 分钟，看日志：

```bash
docker compose logs --tail=80 jenkins | grep -iE 'error|exception|fail'
```

**2. 它自己活着吗（绕过网关）**

```bash
docker compose exec -T jenkins curl -sS -o /dev/null -w '%{http_code}\n' http://localhost:8080/login
```

期望 `200`。这条通但浏览器打不开 → 问题在网关层，不在 Jenkins。

**3. 网关这一层**

```bash
curl -sS -k -o /dev/null -w '%{http_code} %{redirect_url}\n' --resolve jenkins.org-devops.com:443:127.0.0.1 https://jenkins.org-devops.com:443/
```

期望 `302 https://auth.org-devops.com/oauth2/start?rd=...`。
返回 `502` 是上游不通（第 2 步应该也失败）；返回 `404` 是 Caddy 没这个站点（查 `routes.yaml`）。

**4. 登录链路**

```bash
curl -sS -k -o /dev/null -w 'auth: %{http_code}\n' --resolve auth.org-devops.com:443:127.0.0.1 https://auth.org-devops.com:443/ping
curl -sS -k -o /dev/null -w 'dex: %{http_code}\n'  --resolve dex.org-devops.com:443:127.0.0.1  https://dex.org-devops.com:443/dex/healthz
```

`/ping` 期望 `200`，`/dex/healthz` 期望 `200`。哪个失败就查那个服务。
登录页打不开、或登录后无限跳转，几乎都是这一层。

**5. 管理员/配置生效了吗**

```bash
docker compose exec -T jenkins cat /var/jenkins_home/casc/jenkins.yaml | head -20
docker compose exec -T jenkins ls /var/jenkins_home/
```

JCasC 报错不会让容器退出，只在启动日志里打一段。搜 `SEVERE` 或 `ConfigurationAsCode`。

**6. Job 为什么没出现在界面上**

```bash
make jobs-test                       # 先确认定义能渲染
ls .jjb/rendered/*.xml | wc -l       # 期望 3
```

能渲染但推不上去 → 查 `config/jenkins_jobs.ini` 是否存在、Jenkins 是否可达、账号是否有建 Job 权限。

## 常用命令

```bash
# 重启（配置改动后）
docker compose restart jenkins

# 进容器
docker compose exec -it jenkins bash

# 看 JCasC 加载结果
docker compose logs jenkins | grep -iE 'casc|ConfigurationAsCode|SEVERE'

# 备份（会先停服保证一致性）
make backup
```

## 已知边界

- `storage: memory` 的 Dex 重启后 refresh token 失效，已登录会话要重新登录一次
- Jenkins 的 `VERSION` 类参数只对它自己有意义，不要指望它改网关行为

## 警告台账（#92 / REQ-M0-B3）

Manage Jenkins 页面警告逐条处置。抓取时间 **2026-11-06**，运行时 **Jenkins 2.580.2 / Java 21**。
本段结论只针对 213 当前运行时；**警告清单一律从运行时抓取，不得凭印象编写**。

工具：[collect-jenkins-warnings.sh](../../scripts/collect-jenkins-warnings.sh)（只读抓取）、
[check-jenkins-warnings.sh](../../scripts/check-jenkins-warnings.sh)（台账核对）、
[jenkins.warnings](jenkins.warnings)（抓取快照，前者 `--save` 生成）。

### 抓取方式（只读）

在 213 上复跑（凭据只从主仓库 `.env` 读 `JENKINS_ADMIN_ID` / `JENKINS_ADMIN_PASSWORD`，不打印、不入库）：

```bash
cd /tmp/wt-92
bash scripts/collect-jenkins-warnings.sh --save docs/services/jenkins.warnings
```

脚本先 `docker ps --format '{{.Names}}'` 确认容器（默认 `of-jenkins`），再在该容器内直连
`http://localhost:8080/`，用 `curl -s -u "$ID:$PASS"` 抓任务建议的两个端点
`/manage/` 与 `/administrativeMonitor/`，只发 GET，不改 Jenkins 状态。解析取 `/manage/`
里可见（非 `jenkins-hidden`）的 `app-adminmonitor` 区块，外加一条独立的 JCasC `alert alert-warning`。

### 运行时原样输出

命令：

```bash
ssh jenkins@10.22.67.213 'cd /tmp/wt-92 && bash scripts/collect-jenkins-warnings.sh --save docs/services/jenkins.warnings'
```

stderr（HTTP 码与大小，原样）：

```
GET /manage/ -> HTTP=200 size=186576
GET /administrativeMonitor/ -> HTTP=404 size=85867
saved snapshot: docs/services/jenkins.warnings
```

stdout（规范化警告清单，编号 / 运行时标识 / 级别 / 现象，现象截断 300 字，原样）：

```
W-01	jenkins.casc.obsolete.git	warning	Configuration as Code obsolete file format: 'git' is obsolete, please use 'gitSource'
W-02	jenkins.diagnostics.ControllerExecutorsAgents	warning	Building on the built-in node can be a security issue. You should set the number of executors on the built-in node to 0. See the documentation .
W-03	jenkins.monitor.JavaVersionRecommendationAdminMonitor-21-2027-09-30-WARNING	warning	Java 21 end of life in Jenkins You are running Jenkins on Java 21, support for which will end on or after Sep 30, 2027. Refer to the documentation for more details.
W-04	jenkins.security.csp.impl.CspRecommendation	info	Jenkins can enforce Content Security Policy (CSP). CSP tells web browsers what they are allowed to do while rendering a web page. This limits or even eliminates the impact of vulnerabilities like cross-site scripting (XSS). CSP is disabled by default for backward compatibility, but it is recommended
```

`/manage/` HTML 里 `data-monitor-id` 原样提取（5 个，其中 2 个带 `jenkins-hidden` 未激活）：

```
$ docker exec of-jenkins sh -c 'grep -o "data-monitor-id=\"[^\"]*\"" /tmp/w-manage.html'
data-monitor-id="hudson.diagnosis.ReverseProxySetupMonitor"
data-monitor-id="jenkins.diagnostics.ControllerExecutorsAgents"
data-monitor-id="jenkins.diagnostics.URICheckEncodingMonitor"
data-monitor-id="jenkins.monitor.JavaVersionRecommendationAdminMonitor-21-2027-09-30-WARNING"
data-monitor-id="jenkins.security.csp.impl.CspRecommendation"
```

W-01 修复依据 —— JCasC 运行时导出（GET `viewExport` 为 405、POST 无 crumb 为 403，
带 crumb 后 HTTP 200），`scm` 的规范符号就是 `gitSource`，字段与旧 `git` 完全一致：

```yaml
  globalLibraries:
    libraries:
    - defaultVersion: "main"
      name: "orgflow-shared"
      retriever:
        modernSCM:
          libraryPath: "shared-library/"
          scm:
            gitSource:
              credentialsId: "github-token"
              remote: "https://github.com/zeek-zhao/orgflow-devops.git"
```

**可见警告 = 4 条**（W-01 ~ W-04）。页面另有 2 个 `jenkins-hidden` 的 monitor 占位，
不是当前激活的警告，不计入：

| 占位 | 级别 | 状态 |
|---|---|---|
| `hudson.diagnosis.ReverseProxySetupMonitor` | danger | hidden：反向代理检测未触发，当前配置正常（模板文案 "It appears that your reverse proxy set up is broken" 不显示） |
| `jenkins.diagnostics.URICheckEncodingMonitor` | warning | hidden：未激活，文案为空 |

### 台账

处置列只能是「已修」或「不修」；「不修」必须给理由与复核日期。

| 编号 | 现象 | 处置 | 理由 | 复核日期 |
|---|---|---|---|---|
| W-01 | JCasC 报 "Configuration as Code obsolete file format: 'git' is obsolete, please use 'gitSource'"（无 monitor-id 的独立 alert-warning） | 已修 | `config/jenkins.yaml` 的 `scm: git:` 改为运行时导出的规范符号 `gitSource:`（`remote` / `credentialsId` 字段不变），依据见上方 JCasC 导出实证；运行时是否消警见「未验证项」 | 2026-11-13 |
| W-02 | "Building on the built-in node can be a security issue. You should set the number of executors on the built-in node to 0."（ControllerExecutorsAgents） | 已修 | `config/jenkins.yaml` 顶层 `numExecutors: 2` 改为 `0`；5 类 Job 全部 `node('orgflow-docker')`，内置节点无构建负载；agent 节点的 `numExecutors: 2` 保持不变；运行时是否消警见「未验证项」 | 2026-11-13 |
| W-03 | "Java 21 end of life in Jenkins ... support for which will end on or after Sep 30, 2027."（JavaVersionRecommendationAdminMonitor） | 不修 | 是当前 LTS/JDK 组合对**未来** EOL 的预告，Java 21 目前仍受支持；消除它只能换 JDK / 基础镜像，等于靠升降版本绕过（本卡禁止），须与 B1 镜像流程一并决策，不在本卡单独改 | 2027-09-30 |
| W-04 | "Jenkins can enforce Content Security Policy (CSP) ... CSP is disabled by default ... it is recommended to enable it"（CspRecommendation，info 级） | 不修 | info 级建议非故障；启用 CSP 会收紧插件与 Job 页面的内联脚本，需全量 UI 回归，本轮不改运行时；且不能用隐藏/抑制方式「清零」，留专项评估 | 2026-12-06 |

### 台账核对与反证

核对脚本纯文件比对，不连 213，可在 CI 复跑：

```bash
bash scripts/check-jenkins-warnings.sh
```

它断言：① 快照里每个编号都在台账登记（否则报「未登记」）；② 台账里每个编号都在快照里
（否则报「已消解/陈旧」）；③ 每条处置为「已修」/「不修」且理由、复核日期非空。
任一不满足退出码 1。

反证（人为制造一条未登记项）：往 `docs/services/jenkins.warnings` 注入一行
`W-99 ...` → 核对脚本必须报「未登记」且退出码非 0；在台账表格登记 W-99 后复绿。
两次真实输出见交付说明（PR / 交付报告）。

### 未验证项（诚实声明）

1. **`/administrativeMonitor/` 返回 404**：Jenkins 2.580.2 上该路径不是有效端点，
   `/manage/administrativeMonitor/` 同样 404。任务建议的两个地址里只有 `/manage/` 有效，
   警告清单来自 `/manage/` 的可见 `app-adminmonitor` 区块 + 独立 JCasC alert。
2. **网关方式取不到页面**：`curl -k --noproxy '*' -u ... https://jenkins.org-devops.com/manage/`
   返回 `302` 到 `https://auth.org-devops.com/oauth2/start`（forward_auth 拦截），未作为清单来源。
3. **配置修复的运行时效果未验证**：W-01 / W-02 只落在本分支 `config/jenkins.yaml`。
   本轮禁止重启/停止容器、禁止改 213 主工作区，运行中的 Jenkins 挂载的是主工作区配置，
   **因此当前 Manage Jenkins 页面这 4 条仍在、不会自动消失**。需派单方重新部署
   （`USE_GHCR=1 make deploy`）后在管理页人工复核消警情况（卡片「需要人工动作」项）。
4. JCasC 导出端点 GET 405 / POST 需 crumb（无 crumb 403），已带 crumb 成功导出，
   仅用于验证 `gitSource` 写法，未改动 Jenkins 任何状态。
