# jenkins

CI 流水线。跑 `deploy-service` / `backup-service` / `restore-service` 三个参数化 Job。

## 用途与端口

| 项 | 值 |
|---|---|
| 容器名 | `of-jenkins` |
| 固定 IP | `172.31.0.20` |
| 端口 | `8080`（容器内，**不发布到宿主**） |
| 镜像 | **自建** `ghcr.io/zeek-zhao/orgflow-devops/jenkins:24.04-v1`（`FROM jenkins/jenkins:lts-jdk21` + `plugins.txt`） |
| 构建上下文 | `tools/jenkins/` —— compose 里是 `build:` 而不是 `image:` |
| 卷 | `jenkins_home` → `/var/jenkins_home` |

> 为什么自建：官方镜像**一个插件都不带**，而 `deploy-service` 这些是 pipeline job，
> 没有 `workflow-aggregator` 根本跑不起来；另外 213 拉不到 Docker Hub，只能在 CI 构建后推 GHCR。
> 底座 `jenkins/jenkins:lts-jdk21` 由 GitHub runner 拉（runner 有外网），不需要进 mirror。

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

**改了 `tools/jenkins/plugins.txt` 或 `Dockerfile` 之后**：等 main 的 Images 工作流跑完
（只构建 `jenkins` 一个），再 `make images-pin` 回写 `docker-compose.ghcr.yml` 的 digest，
然后重新 deploy。**跳过这一步，213 上跑的还是旧镜像**，而 `make deploy` 不会报任何错。

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
