# Jenkins controller 服务手册

> 状态：适用 | 最后核对：2026-11-25 | 对应分支：feat/m1-jenkins


## 1. 定位
持续集成控制器：M1 唯一构建调度中枢，JCasC 定义全部配置（安全域/授权/节点/凭据/9 条 Job），UI 上点出来的一律不算数。controller 自身 `numExecutors: 0` 不跑构建，所有 Job 在 SSH agent `orgflow-agent` 上执行。

## 2. 依赖
- **LDAP**：`ldap:389`（osixia），登录唯一入口；管理员 `cn=admin,dc=orgflow,dc=local`，口令取自 `LDAP_ADMIN_PASSWORD`（默认 change-me，敏感值走不入库的 `.env`/宿主环境）。
- **dnsmasq**：`IP_DNSMASQ`（192.168.90.15），controller DNS 指向它。
- **Caddy**：公网 `https://<PUBLIC_HOST>/jenkins/` 经 `handle /jenkins/*`（保留前缀）反代到 `jenkins:8080`；Jenkins 自带 `--prefix=/jenkins`。
- **jenkins-agent**：SSH 节点（见 jenkins-agent.md），凭据 `agent-ssh-key` + 固定 host key。

## 3. 端口与入口
- 容器 `8080`，**不发布宿主端口**（expose only）；隔离端口/公网入口均经 Caddy。
- 公网入口 `https://<PUBLIC_HOST>/jenkins/`（JCasC `unclassified.location.url` 用 `${JENKINS_URL}`，由 defaults.env 注入，不写死域名）。
- `/jenkins` 无斜杠 → 308 到 `/jenkins/`（Caddy + router PUBLIC_FIXED 双处同步）；`/jenkins/login` 200 为健康判据。

## 4. 数据
- 命名卷 `orgflow-minimal_jenkins_home` 挂 `/var/jenkins_home`（Job 定义、构建历史、插件；回滚只换 image digest 不丢数据）。
- 只读挂载：`config/jenkins` → `/var/jenkins_home/casc`（JCasC + jobs/*.groovy）、`ci` → `/opt/orgflow/ci`（流水线逻辑）。
- **敏感值不入库**：LDAP 管理员口令、agent SSH 私钥/host key 由 `scripts/gen-jenkins-secrets.sh` 生成 secrets/，宿主 export 透传（`JENKINS_AGENT_SSH_KEY`/`JENKINS_AGENT_HOST_KEY`）。仓库公开，不存任何私钥。

## 5. 运维
- 启动：`./up.sh --only jenkins`（ldap 就绪后）；`docker logs of-jenkins` 须见 `Jenkins is fully up and running` 再起 agent。
- 登录账号：`jenkins-ci`（口令固定 **`Jenkins@2026`**），属组 `jenkins-admins`（全权）；`zeek.zhao` 属 `jenkins-dev`（只读+构建+取消）；匿名无权限。
- **口令轮换**：`slappasswd -s '<新口令>'` 生成 `{SSHA}` → 改 `config/ldap/50-users.ldif` 的 `uid=jenkins-ci` 的 `userPassword` → 重建 ldap 容器让 LDIF 在**空卷**上重新导入；或直接在 LDAP 里 `ldappasswd` 改（已导入的卷不会因 LDIF 改动自动更新）。同步更新本文档口令说明与 CI 凭据。
- **JCasC 自锁兜底**：`jenkins.yaml` 写错（如 LDAP 连不上）会启动即不可登录。出问题时用仓库里的 `jenkins.yaml.bak`（上一版）替换后 `docker compose ... up -d --force-recreate`，**不要**开 `ignoreInvalid` 掩盖错误（错误必须暴露在启动日志）。
- Job 即代码：`config/jenkins/jobs/*.groovy` 生成 9 条 Job；UI 删除后 `POST /jenkins/configuration-as-code/reload` 自动重建；scriptPath 指向 `ci/jenkins/pipelines/*.Jenkinsfile`。
- 资源：`JAVA_OPTS` 含 `-Xmx1g -Xms512m`（宿主内存有限），`restart: unless-stopped`。
- 镜像：CI 构建推 GHCR，compose 用 `${IMAGE_JENKINS:-ghcr.io/.../m1-jenkins@sha256:<CI 回填>}` + `pull_policy: missing`；切源只改 `IMAGE_JENKINS`（ghcr.io ↔ ghcr.nju.edu.cn 同 digest）。

## 6. 验收
- `curl -fsS http://127.0.0.1:18081/jenkins/login` → 200；`curl .../jenkins` → 308 `/jenkins/`。
- LDAP 登录：`curl -u jenkins-ci:Jenkins@2026 https://<PUBLIC_HOST>/jenkins/api/json` → 200；`jenkins-dev` 读 Job 成功但无 Manage Jenkins 入口。
- `/systemInfo` 无 “Obsolete / Failed to load” 告警；`docker logs of-jenkins` 无 JCasC 失败。
- 用例：`tests/bats/08_jenkins.bats`（容器健康、登录页 200、LDAP 登录、Job 全绿、8080 未发布宿主）。
