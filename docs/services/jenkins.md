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
- 登录账号：`jenkins-ci`（口令固定 **`Jenkins@2026`**）属 `jenkins-admins`（全权）；`zeek.zhao` 同时属 `jenkins-admins` 与 `jenkins-dev`（只读+构建+取消）；匿名仅 `Overall/Read`（能看登录页、看不到 Job）。账号/组真源在 `config/ldap/51-jenkins.ldif`。
- **口令轮换**：`slappasswd -s '<新口令>'` 生成 `{SSHA}` → 改 `config/ldap/51-jenkins.ldif` 的 `uid=jenkins-ci` 的 `userPassword` → 重建 ldap 容器让 LDIF 在**空卷**上重新导入；已导入的卷用 `ldappasswd` 或 `ldapmodify` 直接改（LDIF 改动不会自动进已有卷）。同步更新本文档口令说明与 CI 凭据。
- **新增/重建 LDAP 卷后补账号**：空卷首启会按文件名顺序自动导入 `50-users.ldif` + `51-jenkins.ldif`（两者都已挂进 osixia 的 custom bootstrap 目录）；**已有卷必须手跑一次**下面的 ldapadd/ldapmodify 补齐（幂等，先 ldapsearch 查重）：
  ```bash
  # 已有卷一次性补齐 jenkins-ci 账号与两个组（51-jenkins.ldif 的 {{ LDAP_BASE_DN }} 已替换为实际 DN）
  docker cp config/ldap/51-jenkins.ldif of-ldap:/tmp/51-jenkins.ldif
  docker exec -i of-ldap ldapadd -x -H ldap://127.0.0.1:389 \
    -D "cn=admin,dc=orgflow,dc=local" -w "${LDAP_PASSWORD:-change-me}" \
    -f /tmp/51-jenkins.ldif
  # 若 jenkins-admins 已存在但缺第二 member，用 ldapmodify add member（空卷首启已含两 member，无需此步）
  ```
  校验：`ldapsearch -x -b dc=orgflow,dc=local '(cn=jenkins-admins)' member` 应见 jenkins-ci 与 zeek.zhao 两个 member；`curl -u jenkins-ci:Jenkins@2026 $JENKINS_URL/api/json` → 200。
- **JCasC 自锁兜底**：`jenkins.yaml` 写错（如 LDAP 连不上）会启动即不可登录。出问题时用仓库里的 `jenkins.yaml.bak`（上一版）替换后 `docker compose ... up -d --force-recreate`，**不要**开 `ignoreInvalid` 掩盖错误（错误必须暴露在启动日志）。
- Job 即代码：`config/jenkins/jobs/*.groovy` 生成 9 条 Job；UI 删除后 `POST /jenkins/configuration-as-code/reload` 自动重建；scriptPath 指向 `ci/jenkins/pipelines/*.Jenkinsfile`。
- 资源：`JAVA_OPTS` 含 `-Xmx1g -Xms512m`（宿主内存有限），`restart: unless-stopped`。
- 镜像：CI 构建推 GHCR，compose 用 `${IMAGE_JENKINS:-ghcr.io/.../m1-jenkins@sha256:<CI 回填>}` + `pull_policy: missing`；切源只改 `IMAGE_JENKINS`（ghcr.io ↔ ghcr.nju.edu.cn 同 digest）。
- **默认深色主题（T7）**：`config/jenkins/jenkins.yaml` 顶层 `appearance.themeManager`（`disableUserThemes: true`、`theme: "dark"`）是唯一真源，UI 点的一律不算；插件 `theme-manager` + `dark-theme` 钉在 `services/jenkins/plugins.txt`（版本由 update-center 解析，见 `plugins.lock.md`）。生效顺序**必须**「先重建镜像带插件 → 再 reload JCasC」——缺插件时 reload 会因 `No such theme` 让 Jenkins 起不来。若 `dark` 报 `No such theme` 换 `darkSystem`。切勿把 `appearance` 嵌进 `unclassified`（静默不生效）。
- **JCasC reload**：改 `jenkins.yaml` 后需触发重载：`POST /jenkins/configuration-as-code/reload`（带 crumb）。经 Caddy 反代 POST 常因 crumb 校验 403，可在容器内直连执行：
  ```bash
  docker exec of-jenkins bash -c 'CJ=/tmp/cj; CRUMB=$(curl -s -c $CJ -u jenkins-ci:Jenkins@2026 http://localhost:8080/jenkins/crumbIssuer/api/json | sed -n "s/.*\"crumb\":\"\([^\"]*\)\".*/\1/p"); curl -s -b $CJ -X POST -u jenkins-ci:Jenkins@2026 -H "Jenkins-Crumb: $CRUMB" http://localhost:8080/jenkins/configuration-as-code/reload; rm -f $CJ'
  ```

## 6. 排查勘误（避免误判反代）
- **`/jenkins/` 匿名返回 403 白底白字 "Authentication required" 不是 Caddy 反代故障**，而是 Jenkins 权限矩阵行为（响应头 `x-required-permission: hudson.model.Hudson.Read`）。修复是在 `jenkins.yaml` 权限里加 `hudson.model.Hudson.Read:anonymous`（只给 Overall/Read，不给 Item.Read，匿名仍看不到 Job）。修复后匿名访问变成登录页，不再白屏。
- 反代健康的判定标准（与匿名 403 无关）：`/jenkins` → 308、`/jenkins/login` → 200、`/jenkins/static/<hash>/jsbundles/styles.css` → 200、Basic 认证后 `/jenkins/api/json` → 200。`routes.yaml strip:false` + `handle /jenkins/*` + 308 三处都正确，**不要**改成 `handle_path` 剥前缀。
- scheme 泄漏：Funnel→Caddy 是 http，若Jenkins 生成 `http://` 外链（CSP `report-uri` 实测），须在 `config/Caddyfile` 与 `services/router/server.py` render 的 `strip:false` 分支**两处同改** `header_up X-Forwarded-Proto https` + `header_up X-Forwarded-Host {host}`，再 `make routes` 重渲染。宿主机 curl 需 `--noproxy '*'`（本机回环不走代理，否则 403 假象）。

## 7. 冒烟测试（Job 全量触发）
- 一键：`JENKINS_PASS='Jenkins@2026' make smoke`（或 `bash scripts/jenkins-smoke.sh`）。口令只走 env/`JENKINS_PASS_FILE`，**绝不写入脚本/产物**；缺口令立即 exit 2。
- 参数：`--only job1,job2` 指定 Job、`--timeout 900` 单 Job 超时、`--no-wait` 只触发不等、`--dry-run` 只列 Job。
- 流程：取 crumb → 逐个触发 `verify-*` → 解析队列拿 build number → 轮询到结束 → 下载 `consoleText` 到 `artifacts/jenkins-smoke/<UTC时间戳>/<job>-<n>.log`，写 `summary.txt`/`summary.md`。全部 SUCCESS → 0，任一 FAILURE/ABORTED/超时 → 1。
- **反代下 POST crumb 403 时**：设 `JENKINS_CONTAINER=of-jenkins`，脚本改走容器内 `http://localhost:8080/jenkins`（不受反代 Host/MITM 影响）——本沙箱即用此通道实测通过。
- 失败定位：先看 `artifacts/jenkins-smoke/<ts>/` 下对应 `*-<n>.log`，grep `✗` 那行（探针失败点）；`verify-lan-all` 汇总 8 项（7 服务 + jenkins-agent 自身断言）。
- 集成用例：`tests/bats/10_jenkins_smoke.bats`（默认 skip，设 `JENKINS_PASS` 才 dry-run、`RUN_SMOKE=1` 才真实触发）。

## 8. 验收
- `curl -fsS http://127.0.0.1:18081/jenkins/login` → 200；`curl .../jenkins` → 308 `/jenkins/`。
- LDAP 登录：`curl -u jenkins-ci:Jenkins@2026 https://<PUBLIC_HOST>/jenkins/api/json` → 200；`jenkins-dev` 读 Job 成功但无 Manage Jenkins 入口。
- `/systemInfo` 无 “Obsolete / Failed to load” 告警；`docker logs of-jenkins` 无 JCasC 失败。
- 用例：`tests/bats/08_jenkins.bats`（容器健康、登录页 200、LDAP 登录、Job 全绿、8080 未发布宿主）。
