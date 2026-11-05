# jenkins-agent

Jenkins 的构建节点。**所有 pipeline job 实际跑在这个容器里，不是 Jenkins 容器里。**

它存在的唯一理由：Jenkins 主容器**不能**跑 docker。agent 挂宿主 `/var/run/docker.sock`，
所以 job 里 `docker build` / `docker run` 直接驱动 213 的真 daemon（DooD）。

> **这是全仓最容易出问题的组件。** M0 关闭时暴露的三个真机缺陷全部在它身上，
> 而且三个的报错文案都指向别处（「找不到网络」「节点 offline」「证书没导入」）。
> 完整复盘见 [M0 验收记录 §12](../M0-验收记录.md#十二验收过程暴露的缺陷核心复盘)。

## 用途与端口

| 项 | 值 |
|---|---|
| 容器名 | `of-jenkins-agent` |
| 固定 IP | `172.31.0.27` |
| 端口 | `22`（容器内，不发布到宿主） |
| 镜像 | **自建** `ghcr.io/zeek-zhao/orgflow-devops/jenkins-agent:24.04-v1`（`FROM jenkins/ssh-agent:jdk21` + docker CLI） |
| 构建上下文 | `tools/jenkins-agent/` |
| 节点 label | `orgflow-docker`（三个 job 都用 `node('orgflow-docker')`） |
| 执行器数 | `2` |

**它不装 docker daemon**，只装 docker CLI —— daemon 用宿主机的（挂 socket）。

## 入口与依赖

- **入口**：SSH，由 Jenkins 主容器主动连过来（`ssh-slaves` 插件）
- **依赖谁**：`jenkins`（由它发起连接）、宿主 `/var/run/docker.sock`、`orgflow` 网络
- **被谁依赖**：`deploy-service` / `backup-service` / `restore-service` / `nexus-deploy` 四个 job。
  agent 不在，这四个全部 pending，页面只显示 `'orgflow-docker' is offline`

**执行用户是 `jenkins`(uid 1000)，不是 root。** 上游 `jenkins/ssh-agent` 镜像
`PermitRootLogin no`，Jenkins 连进来就是 `jenkins`。这一点是下面第一个坑的根源。

## 部署与配置

```bash
make deploy     # 全栈，含 agent
```

**`secrets/` 下两个文件是前提**，由 `scripts/gen-agent-key.sh` 幂等生成
（`deploy.sh` 会自动调用它，不用手动跑）：

| 文件 | 用途 | 挂到哪 |
|---|---|---|
| `secrets/agent_ssh_key` / `.pub` | Jenkins 连 agent 用的密钥对。**私钥**进 Jenkins 凭据（JCasC `directEntry`），**公钥**注入 agent 容器的 `authorized_keys` | 不挂载，内容通过环境变量传 |
| `secrets/agent_host_key` / `.pub` | agent 的 sshd **host key**。挂载后 `ssh-keygen -A` 见到已存在就跳过，所以重建容器不会换 key | `/etc/ssh/ssh_host_ed25519_key:ro` |

配置分三处：

| 位置 | 作用 |
|---|---|
| `docker-compose.yml` 的 `jenkins-agent` 段 | 挂 socket + host key、`group_add: ${DOCKER_GID}`、`DOCKER_GID` 透传 |
| `tools/jenkins-agent/agent-entrypoint.sh` | 启动时把 `DOCKER_GID` 写进 `/etc/group` 并 `usermod -aG docker jenkins`，然后 `exec setup-sshd` |
| `config/jenkins.yaml` 的 `clouds` 段 | JCasC 定义 SSH agent cloud：host `jenkins-agent`、label、`manuallyProvidedKeyVerificationStrategy` |

### 为什么需要 entrypoint 改 `/etc/group`

`group_add` 只把 gid 加进容器的 OCI spec（`AdditionalGids`），而 **sshd 给登录会话
调 `initgroups()` 会按 `/etc/group` 重置附加组**。结果：

```sh
docker exec -u jenkins of-jenkins-agent id          # groups=1000,998  ← 假阳性
docker exec of-jenkins-agent su -s /bin/sh -c id jenkins   # groups=1000  ← 真实
```

所以**必须在容器启动时改 `/etc/group` 本身**，而不是靠 `group_add`。
同理，**任何验证 agent 权限的命令都必须用 `su`，不能用 `docker exec -u`**。

## 关键环境变量

| 变量 | 作用 | 谁给 |
|---|---|---|
| `DOCKER_GID` | 宿主 `/var/run/docker.sock` 的 gid，entrypoint 用它建 docker 组 | `deploy.sh` / harness / `Makefile` 用 `stat -c %g` 探测后 `export` |
| `JENKINS_AGENT_SSH_PUBKEY` | agent 的 `authorized_keys` 内容 | `deploy.sh` 从 `secrets/agent_ssh_key.pub` 读 |
| `JENKINS_AGENT_HOST_KEY` | 主容器侧用来校验 agent host key 的公钥（「算法 base64」两列） | `deploy.sh` 从 `secrets/agent_host_key.pub` 切两列 |

**这三个都不在 `.env` 里** —— 它们是启动前 `export` 的裸变量，compose 里不带 `=` 透传。

> **docker 组只能用数字 gid**：容器内 `/etc/group` 和宿主对不上（213 宿主 998 叫 `docker`，
> 容器内同 gid 叫 `systemd-network`），按组名 `usermod -aG docker` 会找不到组。

## 排查步骤

**按这个顺序查，不要跳步。** 每一步都对应一个实际踩过的坑。

**1. 容器在吗**

```sh
docker ps -f name=of-jenkins-agent --format '{{.Names}}\t{{.Status}}'
```

**2. Jenkins 认为节点在线吗**

```sh
docker exec of-jenkins curl -s -u "$JENKINS_ADMIN_ID:$JENKINS_ADMIN_PASSWORD" \
  'http://127.0.0.1:8080/computer/api/json?tree=computer[displayName,offline]'
```

期望 `"offline":false`。

> 打域名不行：`jenkins.<domain>` 整站被 oauth2-proxy 包住，带 basic auth 也只会得到 302。
> 必须走容器内 `127.0.0.1:8080`。
> URL 里有 `[...]` 时必须给 curl 加 `-g`，否则 `curl: (3) bad range in URL`。

**3. SSH 本身通吗（隔离「服务端问题」还是「Jenkins 客户端问题」）**

从 213 宿主用 OpenSSH 直连，**用受管的 host key 校验**：

```sh
printf '172.31.0.27 %s\n' "$(cat secrets/agent_host_key.pub)" > /tmp/kh && chmod 600 /tmp/kh
ssh -i secrets/agent_ssh_key -o UserKnownHostsFile=/tmp/kh -o StrictHostKeyChecking=yes \
    -o BatchMode=yes jenkins@172.31.0.27 'echo CONNECTED; id'
```

- 能连上 → 服务端没问题，问题在 Jenkins 的 SSH 客户端（下一步）
- `Connection closed ... [preauth]` → host key 不匹配，见第 5 步

**4. job 里的 docker 能用吗**

```sh
docker exec of-jenkins-agent su -s /bin/sh -c 'id; docker info --format "{{.ServerVersion}}"' jenkins
```

期望 `groups=1000,<DOCKER_GID>` 且打印版本号。

> **绝对不要用 `docker exec -u jenkins ... docker info` 来判断** —— 它会继承
> `AdditionalGids`，永远绿，等于没有判据（这正是缺陷 1「修好」后 job 仍然失败的原因）。
> `deploy.sh` 结尾的端到端检查也改成了走 `su`，并有反向断言禁止改回去。

**5. host key 对吗**

```sh
# 宿主上的 .pub 指纹
ssh-keygen -lf secrets/agent_host_key.pub
# 容器内实际用的私钥指纹
docker exec of-jenkins-agent ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key
```

两个指纹必须相同。不同说明挂载没生效（`docker inspect` 看 `Mounts` 里有没有
`/etc/ssh/ssh_host_ed25519_key`）。

**6. 为什么 job 报「找不到网络 orgflow」**

这**不是**网络问题。真实原因是 job 里的 `docker network inspect` 被 permission denied，
而脚本把它吞成了「网络不存在」。回到第 4 步。

## 常用命令

```sh
# 看日志（sshd 的认证记录在这里）
docker logs --tail=50 of-jenkins-agent

# 确认改 /etc/group 生效了
docker exec of-jenkins-agent getent group docker      # 期望 docker:x:<gid>:jenkins

# 用「和 sshd 一样」的方式验证权限
docker exec of-jenkins-agent su -s /bin/sh -c 'docker info' jenkins

# 重建（会保留 host key，因为它在 secrets/ 里）
USE_GHCR=1 docker compose --env-file .env up -d --no-build --no-deps --force-recreate jenkins-agent
```

## 已知边界

- **只有一个节点、2 个执行器**。并发 3 个 job 会排队，不是故障
- **job 容器和 agent 容器共享宿主 daemon** —— job 里 `docker` 动的是 213 的真容器，
  不是隔离环境。job 里 `docker rm -f` 会删掉真容器
- **host key 不会自动轮换**。要换就删 `secrets/agent_host_key*` 重跑 `gen-agent-key.sh`，
  但 JCasC 的 `manuallyProvidedKeyVerificationStrategy` 也要跟着更新（重启 jenkins）
- **私钥在 `secrets/` 明文**（不进 git）。轮换时两对一起换：`agent_ssh_key` + `agent_host_key`

## 使用指南

```bash
make deploy                                           # 全栈，含 agent
docker exec of-jenkins-agent su -s /bin/sh -c 'id; docker info --format "{{.ServerVersion}}"' jenkins
docker logs --tail=50 of-jenkins-agent
docker exec of-jenkins-agent getent group docker      # 期望 docker:x:<gid>:jenkins
```

**验证权限一律用 `su`**（和 sshd 登录会话一致），不要用 `docker exec -u jenkins`；重建命令见原「常用命令」段。

## 注意事项

- 执行用户是 `jenkins`(uid 1000) **不是 root**；上游镜像 `PermitRootLogin no`（`会话交接.md` §4.1）。
- `group_add` 到不了 SSH 会话：sshd 登录会 `initgroups()` 按 `/etc/group` 重置附加组，必须由 `tools/jenkins-agent/agent-entrypoint.sh` 改 `/etc/group` 本身；`docker exec -u` 会继承 `AdditionalGids` 造成**假阳性**（`会话交接.md` §4.1）。
- docker 组**只能用数字 gid**（`DOCKER_GID`），容器内 `/etc/group` 与宿主对不上，按组名 `usermod -aG docker` 会找不到组（`会话交接.md` §4.1）。
- agent 的 sshd host key 每次重建都变会让节点 offline：host key 必须是 `secrets/` 里的受管产物，并配 `manuallyProvidedKeyVerificationStrategy`；该类构造时就 `parseKey`，**空串会让 JCasC 整份失败**（`会话交接.md` §4.1）。
- 容器 `healthy ≠ 服务可用`：10 容器全 healthy 但 job 全 pending 的坑就在这里，必须有一条打穿全链路的真实 job（`会话交接.md` §4.1）。
- 打 `jenkins.<domain>` 带 basic auth 只得到 302（整站被 oauth2 包住），API 走容器内 `127.0.0.1:8080`；URL 里有 `[...]` 要 `curl -g`（`会话交接.md` §4.3/§4.5）。

## 设置

| 真源 | 路径 |
|---|---|
| 挂 socket / host key / `group_add` | `docker-compose.yml` 的 `jenkins-agent` 段 |
| 启动时改 `/etc/group` | `tools/jenkins-agent/agent-entrypoint.sh` |
| SSH agent cloud / host key 校验策略 | `config/jenkins.yaml` 的 `clouds` 段 |
| 密钥对（不进 Git） | `secrets/agent_ssh_key*` / `secrets/agent_host_key*`，由 `scripts/gen-agent-key.sh` 幂等生成 |
| `DOCKER_GID` | 由 `deploy.sh` / harness / `Makefile` 用 `stat -c %g` 探测后 `export`，**不在 `.env`** |

## 备份

agent **无状态、无数据卷**，不在 `make backup` 范围内；它的身份材料在 `secrets/`（不进 Git），
必须走受控密钥保管另存。丢失时用 `scripts/gen-agent-key.sh` 重建两对密钥，并同步
`config/jenkins.yaml` 的 `manuallyProvidedKeyVerificationStrategy`（重启 jenkins）。
Jenkins 侧的状态备份只保 `jenkins_home`，见 [备份与恢复](../备份与恢复.md)。
