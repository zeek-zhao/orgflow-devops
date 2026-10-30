# 权限管理服务（M0）

```text
浏览器 → Caddy :8080 → oauth2-proxy :4180 → Dex :5556 → OpenLDAP :389
           │            会话校验           OIDC IdP       用户/组
           ├─ /jenkins    forward_auth 成功后 → Jenkins :8080
           ├─ /auth/*    → oauth2-proxy（剥离 /auth）
           ├─ /dex/*     → Dex（保留 /dex）
           └─ /ldapadmin → LDAP Admin → OpenLDAP
```

仅 `/jenkins` 开启 `auth: true`，未登录时由 Caddy 返回 302，
跳转 `/auth/oauth2/start?rd={uri}`。`/nexus`、`/ldapadmin`、`/auth`、`/dex`
不鉴权；尤其 LDAP Admin 不应暴露到公网。认证后透传
`X-Auth-Request-User` / `X-Auth-Request-Email`，不改 Jenkins 自身认证或授权，
也不把 LDAP 组自动映射为 Jenkins 权限。

## 为什么需要 Dex

oauth2-proxy **7.x 已移除 LDAP provider**。实测 v7.3.0、v7.4.0、v7.6.0
的 `--help` 中 `--ldap-*` 数量均为 0；传入 `--ldap-server=...`
直接报 `unknown flag: --ldap-server`。不能使用 `--provider=ldap`；
本项目使用 `--provider=oidc`，由 Dex 查询 LDAP 并签发 OIDC token。

M0 固定浏览器入口为 `http://localhost:8080`，Dex issuer 为
`http://localhost:8080/dex`，client ID 为 `jenkins`。远程访问时可通过
`ssh -L 8080:localhost:8080 <部署主机>` 使用该地址。
更换域名/端口时须同步 issuer、redirectURIs、oauth2-proxy 端点和 whitelist。

**Dex 子路径注意事项：** v2.41.1 的端点路径跟随 issuer；实测
`/keys`、`/healthz` 为 404，`/dex/keys`、`/dex/healthz` 为 200。
因此 `/dex` 路由必须 `strip: false`，内部地址使用
`http://dex:5556/dex/token` 和 `http://dex:5556/dex/keys`。
不能同时使用该 issuer、剥离 `/dex` 和根路径 `/token`、`/keys`。
`--skip-oidc-discovery=true` 配合显式端点，使浏览器走 localhost、
容器走 dex 服务名；`--upstream=static://202` 用于 forward_auth，
真正的 Jenkins 反代仍由 Caddy 完成。

## 启动与导入

1. `cp .env.example .env`，替换 `LDAP_ADMIN_PASSWORD`、
   `OAUTH2_CLIENT_SECRET`、`OAUTH2_COOKIE_SECRET`。最后一项的示例为
   **32 个字符的占位值，不可用于生产**；可用 `openssl rand -hex 16`
   生成新的 32 字符值。保持 `LDAP_DOMAIN=devops.com`、
   `OAUTH2_CLIENT_ID=jenkins`，Dex 和代理共用同一个 client secret。
   Dex static client 通过原生 `secretEnv: OAUTH2_CLIENT_SECRET` 读取环境变量；
   v2.41.1 不会展开 static client 的 `secret: ${OAUTH2_CLIENT_SECRET}`，
   直接写该占位会导致回调 `invalid_client`。LDAP connector 的 `bindPW`
   则支持 `${LDAP_ADMIN_PASSWORD}` 展开。
2. 生成路由并启动（不需要启动 Jenkins 即可验证未登录的 302）：

   ```bash
   make render
   docker compose up -d ldap ldapadmin dex oauth2-proxy caddy router
   docker compose ps
   ```

3. 等 LDAP healthy 后执行导入；脚本和 LDIF 已只读挂载到 LDAP 容器，
   管理员密码从该容器环境变量读取：

   ```bash
   docker compose exec -T ldap bash /opt/orgflow-auth/bootstrap-ldif.sh --dry-run
   docker compose exec -T ldap bash /opt/orgflow-auth/bootstrap-ldif.sh
   ```

   也可在具备 Bash 和 OpenLDAP 客户端的机器上执行：

   ```bash
   LDAP_URI=ldap://<可达的LDAP地址>:389 \
   LDAP_BASE_DN=dc=devops,dc=com \
   LDAP_ADMIN_DN=cn=admin,dc=devops,dc=com \
   LDAP_ADMIN_PASSWORD='<管理员密码>' \
     services/auth/bootstrap-ldif.sh
   ```

脚本严格按 **users → departments → app** 导入，不修改仓内 LDIF 或 DN。
`ldapadd -c` 允许重复执行，`Already exists (68)` 不导致脚本失败，
不会覆盖已存在用户或已修改的密码。单条 entry 错误会显示 LDAP 原始诊断并继续，
非 68 错误额外打印 WARNING；连接/绑定失败立即终止。`--dry-run`
只打印命令，不连接、不写库、不输出密码。结束时通过子树 `ldapsearch`
与 `grep -c '^dn:'` 打印条目数。

环境变量默认值：`LDAP_URI=ldap://ldap:389`、
`LDAP_BASE_DN=dc=devops,dc=com`、`LDAP_ADMIN_DN=cn=admin,dc=devops,dc=com`；
`LDAP_ADMIN_PASSWORD` 无脚本内默认值，必须提供。
现有卷的 base DN 不会随 `LDAP_DOMAIN` 自动迁移；如已有其他目录，
先备份并另行迁移，不能通过改写这些 LDIF 来适配，也不要删除生产卷。

已知数据限制：

- `users.ldif` 的用户在 `ou=users`，含 `inetOrgPerson + posixAccount`，
  Dex 以 `uid` 登录，读取 `mail`、`cn`，支持目录中已有的 `{MD5}` 密码。
- `departments.ldif` 中 `groupOfNames.member` 指向不存在的 `ou=people`。
  悬空引用保持原样；服务器若拒绝某条 entry，脚本报告后仍继续导入 app。
- `app.ldif` 的 `posixGroup.memberUid` 是用户名而非 DN，gidNumber 为
  503–511；Dex 用 `uid → memberUid` 匹配，在 `ou=groups` 子树搜索，
  不使用 departments 的悬空引用。

## 首次登录与改密

访问 `http://localhost:8080/jenkins`，依次跳转 oauth2-proxy、Dex 的
OpenLDAP 登录页。默认导入账号为 `admin.zeek`（DN：
`cn=Admin Zeek,ou=users,dc=devops,dc=com`），初始密码为 `123456`，
仅限首次本地验证，**立即改密**。若出现授权确认页，按提示同意。OIDC 回调
`/auth/oauth2/callback` 写入会话 cookie 后返回 Jenkins。
Jenkins 未启动时，认证成功后的最终上游请求会返回 502，而不是登录失败。

LDAP 管理员用 DN `cn=admin,dc=devops,dc=com` 和
`LDAP_ADMIN_PASSWORD`（Compose 占位默认 `change-me`）登录
`http://localhost:8080/ldapadmin/`，修改对应用户的 `userPassword`，
新密码优先选择 SSHA。也可交互式执行，避免把新密码放进命令行：

```bash
docker compose exec ldap ldappasswd -x -H ldap://localhost:389 \
  -D cn=admin,dc=devops,dc=com -W -S \
  'cn=Admin Zeek,ou=users,dc=devops,dc=com'
```

修改 `.env` 中的 LDAP 管理员密码不会自动更新已有 LDAP 卷里的密码；
须先在目录中修改，再同步环境变量并重建 ldap/Dex。
M0 cookie 不保证随 LDAP 改密立即失效；改密后应清理浏览器会话并重新登录。

## 验收与应急

```bash
docker compose config -q
bash -n services/auth/bootstrap-ldif.sh
python3 services/auth/test_bootstrap.py
python3 services/router/test_render.py
docker compose ps  # ldap、dex、oauth2-proxy 应为 healthy
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8080/auth/ping  # 200
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8080/jenkins   # 302
docker compose exec ldap ldapsearch -x -H ldap://ldap:389 \
  -D cn=admin,dc=devops,dc=com -W \
  -b dc=devops,dc=com -s sub '(uid=admin.zeek)' dn
```

应急时绕过 Caddy，直接访问 **Jenkins 容器的 8080**。当前 Compose
仅 `expose: 8080`，没有宿主机端口映射；不应把网关的 `localhost:8080`
误认为 Jenkins 直连口，也不在此任务中改 Jenkins 配置。在 Linux Docker
宿主机可获取其容器 IP 后访问（Jenkins 须已启动）：

```bash
docker inspect --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' of-jenkins
curl http://<上一步容器IP>:8080/
```

已有部署若另有 loopback 应急端口映射，应保留并使用该端口。
应急直连仍受 Jenkins 自身认证控制，不应向公网开放。

### 健康检查的边界

LDAP 使用管理员绑定探测 base DN（密码经 stdin 传递，不放进进程参数）。
该镜像默认 ACL 不允许匿名读取目录；匿名 `ldapsearch -x -b dc=devops,dc=com`
会返回 `No such object (32)`，不能用作健康检查或用户存在性验收，
也不为通过该检查而放宽目录 ACL。Dex 探测 `/dex/healthz`。oauth2-proxy v7.6.0
镜像是 **distroless**，无 sh/wget/curl/nc；
实测 `--entrypoint sh` 报 `exec: "sh": executable file not found`，
不能用 CMD-SHELL/curl。其 healthcheck 只能执行
`["CMD", "/bin/oauth2-proxy", "--version"]`：这是进程/可执行文件级探测，
不是 HTTP 或登录可用性检查，healthy 不证明代理已就绪或 LDAP 可登录。
实际服务由 `/auth/ping`（上游 `/ping`）及 Caddy forward_auth 验证；
完整 OIDC 登录还需浏览器登录测试。

## M0 限制与 M1 演进

Dex 使用内存 storage，**重启会丢失 refresh token、授权状态和签名密钥**，
现有会话可能需要重新登录。M0 仅适合可信网络内的本地验证：
LDAP 明文连接，cookie `secure=false`，未对 LDAP Admin 或 Nexus 增加统一认证。

M1 将 Dex 替换为 Keycloak，迁移到持久化存储并细化组/角色授权；
启用网关 TLS、LDAP TLS，cookie 改 `secure=true`，使用正式域名并同步全部
issuer/callback/whitelist 配置，收紧 IdP 校验、管理台入口和应急口访问。
