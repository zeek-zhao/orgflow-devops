# [36] ldapadmin 网关鉴权：一句话说清交付物

- **Issue**：#36（需求真本）
- **分支**：`feat/36-ldapadmin-auth`
- **依赖**：无（oauth2/Dex 链路已在 #32 真机验收过）
- **token 预算**：约 3 万 token；超预算先停下汇报，不要硬推

## 目标

`https://ldapadmin.<domain>/` 不再匿名可达：未登录访问由 Caddy 直接 302 到
`auth.<domain>/oauth2/start`（与 jenkins 站点同一套网关鉴权），登录后正常使用
phpLDAPadmin。M0 文档自认的最后一个生产阻塞项关闭。

## 背景与取证

| 事实 | 值 / 结论 | 怎么来的 |
|---|---|---|
| 网关鉴权是路由级开关，机制已存在 | 路由 `auth: true` → `render.py` 生成 `forward_auth oauth2-proxy:4180` 块 | `services/router/render.py`，jenkins 站点现状 |
| oauth2 cookie 覆盖全部子域 | `--cookie-domain=.<GATEWAY_DOMAIN>`，登录一次全站有效 | `docker-compose.yml` oauth2-proxy command |
| Dex 侧无需新增客户端 | oauth2-proxy 单实例服务所有 forward_auth，redirect 统一 `auth.<domain>/oauth2/callback` | 同上 |
| 改动前 ldapadmin 匿名 200 | `docs/services/ldapadmin.md` 自认「能打开就能改数据」 | 该文档「入口与依赖」节 |

## 范围

**改**

| 文件 | 改法 |
|---|---|
| `config/routes.yaml` | ldapadmin 路由加 `auth: true` |
| `services/router/test_render.py` | `forward_auth` 计数 1→2；新增 `test_ldapadmin_site_is_gateway_protected`（含 nexus 不受波及的反向校验） |
| `tests/bats/11_ldapadmin.bats` | 匿名 200→302，断言 Location 指向 `auth.<domain>/oauth2/start` 且带 `rd=` |
| `tests/bats/14_caddy.bats` | `assert_gw ldapadmin / 302`、`forward_auth` 计数 1→2 |
| `tests/bats/20_tls.bats` | `--cacert` 用例 ldapadmin 期望 302 |
| `scripts/deploy.sh` | 完成提示 ldapadmin 标注「受保护」 |
| `README.md` / `docs/M0-最小核心.md` / `docs/network/arch.md` | 登录列表同步 |
| `docs/services/ldapadmin.md` | 入口改两层登录说明；排查第 3 步期望 200→302 |
| `config/homepage/services.yaml` | 卡片标注需登录；顺带修 IP 笔误 .22→.23 |

## 验收

- [ ] `make test` → render 套件 20 用例 OK（含新增 #36 用例）
- [ ] `make render && grep -c forward_auth out/Caddyfile` → `2`
- [ ] 真机：`curl -sk -o /dev/null -w '%{http_code}' --resolve ldapadmin.<domain>:443:127.0.0.1 https://ldapadmin.<domain>/` → `302`
- [ ] 真机反证：`curl -sk -o /dev/null -w '%{http_code}' --resolve nexus.<domain>:443:127.0.0.1 https://nexus.<domain>/` → `200`（公开站点未被波及）
- [ ] 人工：Windows 浏览器未登录打开 ldapadmin 跳登录页，Dex 登录后见 phpLDAPadmin

## 禁止事项

- 不得改 oauth2-proxy / Dex 配置：机制已存在，只动路由声明
- 不得动 `ldap` 服务本身与 `tests/images.lock`
- 不得为了过测试放宽 302 断言（如改成「2xx/3xx 都行」）

## 依赖与前置

- [x] 213 真机 oauth2 登录链路可用（#32 已验）
- [x] `config/routes.yaml` 是路由唯一真源（ADR-13）

## 交付物

- [ ] 分支 `feat/36-ldapadmin-auth`，提交信息符合 `docs/提交规范.md`
- [ ] PR 正文含：做了什么 / 关键决策与偏离 / 验收实测表 / 未验证项
- [ ] 验收输出贴进 PR 正文（命令 + 真实输出，不要转述）

## 交付后的记录

完成后由派单方补充，执行方不用填：

- PR：#
- 结果：
- 与本卡的偏离：
