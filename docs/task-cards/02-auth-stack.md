# [02] 权限管理服务：OpenLDAP + LDAP Admin + Dex + OAuth2 Proxy

- **Issue**：#2
- **PR**：#7
- **分支**：`feat/2-auth-stack`
- **类型**：回溯重建（原文是一段话的派单 prompt，验收口径按当前仓库状态重写）
- **依赖**：#1（`render.py` 需要支持 `auth: true`）
- **token 预算**：约 12 万 token

## 目标

把「登录」变成一套服务，而不是每个应用各配一份账号：

- `OpenLDAP` 存用户与部门（沿用既有生产 LDIF，不改 DN）
- `LDAP Admin` 提供可点的管理界面
- `Dex` 作为 OIDC IdP，后端接 LDAP
- `OAuth2 Proxy` 作为网关侧会话守卫

终态：受保护站点在 `routes.yaml` 里写 `auth: true`，未登录访问被跳到统一登录页；
登录后回到原地址。**应用自己不实现登录**。

## 背景与取证

开工前先看这张表，**不要重新假设**：

| 事实 | 值 / 结论 | 怎么来的 |
|---|---|---|
| `oauth2-proxy` 7.x 已移除 LDAP provider | v7.3.0 / v7.4.0 / v7.6.0 的 `--help` 中 `--ldap-*` 均为 0 项，传 `--ldap-server` 直接 `unknown flag` | `docker run --rm quay.io/oauth2-proxy/oauth2-proxy:v7.6.0 --help \| grep -c ldap` |
| 因此必须引入 Dex | 原 ADR-06「OAuth2Proxy 直连 LDAP」不可行 → **ADR-09**：Dex 充当 IdP | 同上 |
| base DN 沿用 `dc=devops,dc=com` | 直接复用既有生产 LDIF，零 DN 改写、零迁移风险（**ADR-10**）。故 `LDAP_DOMAIN` 从 `orgflow.internal` 改为 `devops.com` | 既有 `users.ldif` 的 DN |
| Dex 不展开 `secret` 里的 `${...}` | 必须用原生 `secretEnv` 字段读环境变量 | `services/auth/dex/config.yaml` 实测 |
| `OAUTH2_COOKIE_SECRET` 必须 32 字节 | 20 字符的旧默认值会导致启动即报错 | `docker logs of-oauth2` |
| LDAP 幂等导入的「已存在」退出码是 68 | `ldapadd` 对 `entry already exists` 返回 68，**不是** 0 | `ldapadd ... ; echo $?` |
| Dex 用 `storage: memory` | 重启丢 refresh token，属已知限制，M1 换持久化 | `docker logs of-dex` |

## 范围

**改**

| 文件 | 改法 |
|---|---|
| `config/routes.yaml` | 新增 `dex` 路由；`jenkins` 路由加 `auth: true` |
| `services/router/render.py` | 路由支持 `auth: true` → 输出 `forward_auth oauth2-proxy:4180` + 401 时 `redir` 到登录入口 |
| `services/router/test_render.py` | 补 `auth: true` 的渲染断言与「无 auth 时不输出 forward_auth」的反向断言 |
| `docker-compose.yml` | 新增 `dex`；`ldap` / `dex` / `oauth2-proxy` 补 healthcheck；oauth2-proxy 改 `--provider=oidc` + `--skip-oidc-discovery` + 显式端点 |
| `.env.example` | `OAUTH2_COOKIE_SECRET` 改为合法 32 字符；补 `LDAP_*` / `DEX_*` 说明 |
| `.gitignore` | 忽略派单临时卡 `TASK-*.md` |
| `services/auth/README.md` / `services/router/README.md` | 部署、账号初始化、排查 |

**新增**

| 文件 | 内容 |
|---|---|
| `services/auth/ldif/users.ldif` / `departments.ldif` / `app.ldif` | 既有生产 LDIF 原样迁入 |
| `services/auth/bootstrap-ldif.sh` | 幂等导入：68 视为成功，传输/绑定错误立即中止；密码走临时 600 文件不进 argv；支持 `--dry-run` |
| `services/auth/dex/config.yaml` | LDAP connector + static client |
| `services/auth/test_bootstrap.py` | 纯逻辑测试：导入脚本的参数、幂等判定、密钥不落 argv |

## 验收

- [ ] `python3 services/auth/test_bootstrap.py` → 退出码 `0`
- [ ] `python3 services/router/test_render.py` → 退出码 `0`
- [ ] `grep -c 'forward_auth' out/Caddyfile` → `1`（只有 `auth: true` 的站点）
- [ ] `grep -A2 'forward_auth' out/Caddyfile \| grep -c 'uri /oauth2/auth'` → `1`
- [ ] `bash -n services/auth/bootstrap-ldif.sh` → 退出码 `0`
- [ ] `docker compose config -q` → 退出码 `0`
- [ ] `make test-bats` → `10_ldap` / `11_ldapadmin` / `12_dex` / `13_oauth2_proxy` 四个用例文件全 pass
- [ ] LDAP 条目数 `ldapsearch -b dc=devops,dc=com -s sub "(objectClass=*)" dn | grep -c ^dn:` → `33`
- [ ] 重复跑 `bootstrap-ldif.sh` → 仍 `33`（幂等）
- [ ] 反证：把 `config/routes.yaml` 里 jenkins 的 `auth: true` 删掉 → `grep -c 'forward_auth' out/Caddyfile` 变 `0`，且 `13_oauth2_proxy.bats` **必须红**
- [ ] 反证：把 `routes.yaml` 里 `name: auth` 那条路由删掉 → `make render` **非 0 退出**，报「缺少 name: auth 的路由」

## 禁止事项

- 不得改 LDIF 里的 DN（`dc=devops,dc=com` 是既有生产数据的真源，改了就是一次迁移）
- 不得把 LDAP 管理员密码、`OAUTH2_COOKIE_SECRET`、`OAUTH2_CLIENT_SECRET` 写进任何入库文件
- 不得在 `bootstrap-ldif.sh` 里用 `ldapadd -w <密码>`（会进进程表）；必须走 `-y <临时文件>`
- 不得让 68 以外的任何 `ldapadd` 错误被当成成功
- 不得自行合并 PR

## 依赖与前置

- [ ] `docker compose version` → `v2.x`
- [ ] `.env` 里 `OAUTH2_COOKIE_SECRET` 长度 = 32
- [ ] 端口 `389` / `5556` / `4180` 未被占用（或已在 `.env` 改端口）

## 交付物

- [ ] 分支 `feat/2-auth-stack`
- [ ] PR 正文含：做了什么 / **对原计划的修正（ADR-09/ADR-10）** / 验收实测表 / 已知限制
- [ ] 已知限制必须写进 `services/auth/README.md`，不能只写在 PR 里

## 当年实测（PR #7 记录）

| 项 | 结果 |
|---|---|
| `test_render.py` | 10/10 |
| `test_bootstrap.py` | 6/6 |
| 渲染路由数 | 5（jenkins/nexus/ldapadmin/auth/dex） |
| 容器健康 | `of-ldap` / `of-dex` / `of-oauth2` 均 healthy |
| `/auth/ping` | 200 |
| `/jenkins` | 302 → `/auth/oauth2/start?rd=/jenkins` |
| `/dex/keys` | 200 |
| LDAP 条目数 | 33（重复导入仍 33） |
| 完整 OIDC 登录 | `admin.zeek` → 换码 → 签名校验 → 会话校验 **202** |

## 与本卡的偏离

- 当年走 HTTP、`--cookie-secure=false`；ADR-13 上 TLS 后已改回
- 当年的 `/auth`、`/jenkins` 是路径前缀，现在是 `auth.<domain>` / `jenkins.<domain>`；
  验收命令已按域名模型改写
- 当年 `AUTH_SUBDOMAIN` 是独立变量，后来发现它与 `routes.yaml` 形成两处真源，
  已在 #18 删除——登录跳转目标只由 `name: auth` 那条路由决定
