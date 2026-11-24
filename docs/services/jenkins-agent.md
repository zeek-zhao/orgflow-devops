# Jenkins agent 服务手册

> 状态：适用 | 最后核对：2026-11-25 | 对应分支：feat/m1-jenkins


## 1. 定位
SSH 构建执行节点：9 条局域网检测 Job 全部在 `orgflow-agent` 节点上跑，controller 不跑构建。探测脚本放宿主 `ci/shared-library`，挂进容器即共享库——改宿主文件下一次构建立即生效，不重建容器、不拉 Git 库。**无 docker.sock**（本轮 Job 只做局域网探测；后续部署 Job 另建"部署 agent"，不混用）。

## 2. 依赖
- **Jenkins controller**：`jenkins:8080`（SSH launcher 连 `jenkins-agent:22`）；节点永久定义、2 executors、label `orgflow-agent`、remoteFS `/home/jenkins/agent`。
- **dnsmasq**：`IP_DNSMASQ`（192.168.90.15），容器内 DNS 指向它（`dig home.<DOMAIN>` 必须解析到 192.168.90.10）。
- **共享库**：宿主 `ci/shared-library` → 容器 `/opt/orgflow/shared:ro`（755/644，jenkins 可读不可写）。
- **LDAP**：探测 LDAP 服务时需要管理员口令，由 Jenkins 凭据 `ldap-admin-password` 经 `withCredentials` 注入 `LDAP_BIND_PASSWORD`，脚本写临时文件 `-y` 传入（不进命令行/console）。

## 3. 端口与入口
- 容器 `22`（sshd），**不发布宿主端口**（expose only）；无 HTTP 入口、无独立 Web UI。
- 镜像 `jenkins/ssh-agent:9.8.0-jdk21`（Debian，用户 jenkins UID 1000 普通用户、无 sudo、不入 docker 组）；Java 在 `/opt/java/openjdk/bin/java`（与 JCasC `javaPath` 一致）。
- 固定 IP `192.168.90.17`，容器名 `of-jenkins-agent`。

## 4. 数据
- 无持久化数据卷（探测无状态）；SSH host key 与登录密钥是受管产物，由 `scripts/gen-jenkins-secrets.sh` 幂等生成 `secrets/`（gitignore，不进仓库）：
  - `agent_host_key` → 挂 `/etc/ssh/ssh_host_ed25519_key`（跨容器重建稳定）；
  - `agent_ssh_key.pub` → 挂 `/run/secrets/agent_ssh_pub`（入口脚本写 authorized_keys）；
  - `agent_ssh_key` → 宿主 export `JENKINS_AGENT_SSH_KEY`（JCasC directEntry 凭据，不落仓库）。
- host key 校验用 `manuallyProvidedKeyVerificationStrategy.key`（显式期望值），**不用** `manuallyTrusted`（容器重建换 key 会脱机）。

## 5. 运维
- 启动顺序：controller 出现 `Jenkins is fully up and running` 后再 `./up.sh --only jenkins-agent`，否则 agent 反复重连。
- 容器内工具（以 jenkins 用户验证）：`curl`/`dig`/`ldapsearch`/`ping`/`nc`/`jq`/`git`/`bash`/`java`；时区 `Asia/Shanghai`。
- **普通用户身份**：容器 PID 1 是 root（sshd 绑 22 需要），但 SSH 会话用户是普通用户 jenkins（uid 1000，非 root、无 sudo、无 docker 组）。验收必须 `docker exec -u jenkins ...` 或真实 Job 里 `id` 验证，root 能跑不算通过。
- **不要切 USER**：Dockerfile 末尾保持 `USER root`，只在 apt install 前显式 `USER root`；切回 jenkins 会让 entrypoint 无法启动 sshd。
- 挂载权限：宿主 `chmod -R a+rX ci/shared-library`（脚本已自动做）；Job 不得往 `/opt/orgflow/shared` 写文件（ro 挂载）。
- 资源：`mem_limit: 512m`（探测足够），`restart: unless-stopped`。
- 健康：`timeout 2 bash -c '</dev/tcp/127.0.0.1/22'`（不依赖 curl/nc；up.sh 只认容器 Health，不看 manifest 的 `health_url`）。

## 6. 验收
- `/computer/api/json` 里 `orgflow-agent` `offline=false`。
- `docker exec -u jenkins of-jenkins-agent id` → `uid=1000(jenkins)`；`dig -v`/`ldapsearch -VV`/`curl -V`/`java -version` 均以 jenkins 身份有输出。
- Job `verify-jenkins-agent` 绿（真实 SSH 会话里跑 `id` 返回 uid 1000、java/dig 可用）。
- 共享库即时生效：宿主改 `ci/shared-library/bin/check-lan.sh` 加一行 echo → 不重建容器直接重跑 → console 立刻出现新输出；`docker exec of-jenkins-agent ls /opt/orgflow/shared/bin` 能看到同一份文件。
- 用例：`tests/bats/09_jenkins_agent.bats`。
