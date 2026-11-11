# M0-A · 身份与权限（REQ-M0-A*）

> 需求基线 · DOC-R-005 ｜ 状态：approved ｜ 负责人：zeek.zhao ｜ 评审日期：2026-11-11 ｜ 复审：12 个月
> 本域 7 条，覆盖 Issue #2 #84 #85 #86 #87 #88 #89（全部已关闭）。
> 规则见 [需求基线入口](README.md)：**要求与判据冻结，现状与证据可变**；判据前的 ⚠ 表示干净 clone 上复现不出来。

## 1. 需求表

| 编号 | 要求 | 验收判据 | 现状 | 证据 |
|---|---|---|---|---|
| **REQ-M0-A0** | 提供 LDAP 目录 + 管理界面 + 网关前置认证，未登录不得进入受保护站点 | `bats tests/bats/10_ldap.bats tests/bats/11_ldapadmin.bats tests/bats/13_oauth2_proxy.bats` → 退出码 0 | 已实现 | [#2](https://github.com/zeek-zhao/orgflow-devops/issues/2) · PR #7 #74 #109 |
| **REQ-M0-A1** | 身份命名规范转正为决策真本；LDIF 硬缺陷清零（uidNumber 唯一、口令换 SSHA、注释与组归属正确）；**uid 字符串不变** | `grep -c '{MD5}' services/auth/ldif/users.ldif` → `0`；`grep -c '{SSHA}' services/auth/ldif/users.ldif` → `10`；`awk '/^uidnumber:/{print $2}' services/auth/ldif/users.ldif \| sort \| uniq -d` → 空；反证：把两个 uidNumber 改回相同 → `10_ldap.bats` 必须红 | 已实现 | [#84](https://github.com/zeek-zhao/orgflow-devops/issues/84) · PR #97 #100 #101 #102 |
| **REQ-M0-A2** | 全部用户 DN 统一为 `uid=<uid>,ou=users,dc=devops,dc=com`，全库旧 uid 引用归零，登录链路可回归 | ⚠ 原判据「uid 与命名规范 §5 映射表逐字一致」依赖已归档文档。替代：`python3 scripts/migrate_identity.py --verify` → 退出码 0（Windows 上的假红已于 2026-11-11 修复，见 §2）；`bats tests/bats/10_ldap.bats` 绿 | 已实现 | [#85](https://github.com/zeek-zhao/orgflow-devops/issues/85) · PR #107 #112 #113 |
| **REQ-M0-A3** | 网关按组授权，只守无原生认证能力的静态内容；伪造 `X-Forwarded-*` 不可行；权限一律由 `posixGroup.memberUid` 决定 | `bats tests/bats/36_gateway_acl.bats` 绿；`docker compose config \| grep -c trusted-proxy-ip` ≥ `1`；反证：临时去掉 `--allowed-group` → 非组成员用例必须红 | 已实现 | [#86](https://github.com/zeek-zhao/orgflow-devops/issues/86) · PR #118 #123 #124 |
| **REQ-M0-A4** | Jenkins 只有一道 LDAP 登录，权限由组决定，不再有 `loggedInUsersCanDoAnything`，不再经网关 OIDC | `grep -c loggedInUsersCanDoAnything config/jenkins.yaml` → `0`；`bats tests/bats/16_jenkins.bats` 绿；反证：把 `java.naming.referral` 改成 `follow` → 静态检查必须红 | 部分 | [#87](https://github.com/zeek-zhao/orgflow-devops/issues/87) · PR #125 |
| **REQ-M0-A5** | Nexus / phpLDAPadmin 直连 LDAP；文档站成为唯一走网关的受保护路由 | `bats tests/bats/36_gateway_acl.bats` 绿（首条断言：`forward_auth` 只剩 1 处且不属于 jenkins）；`bats tests/bats/17_nexus.bats` 绿 | 已实现 | [#88](https://github.com/zeek-zhao/orgflow-devops/issues/88) · PR #125 |
| **REQ-M0-A6** | 「权限全部由组决定」变成可复跑的用例集（组 × 服务 × 允许/拒绝），**至少 3 个必拒格** | `grep -c '必须被拒' tests/bats/36_gateway_acl.bats` ≥ `3`；反证：给非组成员临时加 `memberUid` → 对应用例必须由红转绿 | 部分 | [#89](https://github.com/zeek-zhao/orgflow-devops/issues/89) |

## 2. 要点与坑（只在踩过的地方写）

### A2：原定的「带回滚 LDIF 的热迁移」没有执行

需求原文禁止「在线上直接 `ldapmodify` 而不留回滚 LDIF」。实际执行时改成**删卷重建 + 重新导入完整 LDIF**，因此**不存在回滚 LDIF**。这不是实现偷懒，是当时的决策：目录里只有 10 个演示账号，热迁移的回滚脚本比重建更容易出错。

代价写在需求里，不被「已完成」掩盖：旧备份包没有随之更新，`verify-*` 系列 Job 有静默回滚到旧 uid 的风险 —— 这条风险没有在本轮复核，属于未关闭项。

### A2：判据脚本在 Windows 上必然误报（2026-11-11 已修）

`scripts/migrate_identity.py --verify` 的旧 uid 残留扫描有两个平台缺陷：

```python
p = os.path.normpath(os.path.join(dirpath, fn))   # Windows 上得到 scripts\migrate_identity.py
if p in ALLOW_OLD:                                 # ALLOW_OLD 里是 scripts/migrate_identity.py
    continue
```

1. `normpath` 在 Windows 产出反斜杠，而 `ALLOW_OLD` 用正斜杠 → **allowlist 永不生效**，脚本会命中自己的映射表；
2. 跳过目录的判据是 `'/out' in dirpath`，Windows 上目录是 `.\out` → **`out/` 不被跳过**。

2026-11-11 实测：Windows 上 `--verify` 报 25 处命中、rc=1，其中 17 处来自 `out/` 与脚本自身的 `MAPPING`，**在 POSIX 路径下均不会命中**。所以这条判据目前只能在 Linux / CI 上作为闸门，不能作为本地门禁 —— 属于「假红」，与过去「门禁超时被杀」是同一类问题。

**已修（同日）**：路径一律经 `pathlib.PurePath(...).as_posix()` 归一后再比对，反斜杠与正斜杠不再混用。
反证：在 `docs/_probe/leak.md` 写一行旧 uid → `--verify` 报 1 处并给出 POSIX 路径；删除后复绿。
影响不止「一条测试红」：本机 `make test` 之前恒红，门禁因此被当成噪音 —— 那是假红最贵的代价。

### A2 补充：映射表的真源已经不在仓库里

`services/auth/ldif/*.ldif` 的 uid 映射表原本规定「唯一真源 = `docs/身份命名规范.md` §3」。该文档按最小披露剔除后，**映射事实只存在于 `scripts/migrate_identity.py` 的 `MAPPING` 字典里**，脚本 docstring 仍指向一个不存在的路径。

这不影响迁移已完成这一事实，但影响可复现性：以后想核对「某个账号为什么叫这个名字」，得读脚本。

### A4：`现状 = 部分` 的原因

配置层的要求全部满足（`loggedInUsersCanDoAnything` 已为 0、`securityRealm.ldap` 已生效）。缺的是**判据里那一条「非组成员登录 Jenkins 后无法访问 `/manage/`」没有自动化断言**：`16_jenkins.bats` 只有 1 个用例，验的是「容器内 `/login` 就绪」，验不了组授权。

所以「Jenkins 组授权真的生效」目前只有当时的真机人工取证，仓里没有任何东西能在 CI 里拦住它的回归。

### A6：`现状 = 部分` 的原因

要求写的是「矩阵」，实际落地的是**两个用例**：一个组成员放行、一个非组成员拒绝。

- 已满足：存在必拒格，且断言方式正确（`allowed-group` 不匹配 → 403）。
- 未满足：要求 ≥ 3 个必拒格，实际 1 个。缺的是「不同组对不同服务的交叉拒绝」——现在只有文档站一条路由受保护，交叉矩阵在 A5 之后大部分路由已无组概念，**要求本身已经比现状超前了**。

**这条不是可以靠补测试解决的**：它说明 A6 的需求表述在 A5 之后部分失效。是否把 A6 改写为「对唯一受保护路由的拒绝行为有自动化断言（1 格即可）」，属于需求变更，需要走 CHANGE 流程 —— 本轮不动，留给下一轮决策。

### A5 的一个副作用

A5 把 Jenkins / ldapadmin 从网关摘掉之后，「网关按组授权」的覆盖面从 2 条路由缩到 1 条。这意味着 **A3 的组授权能力只在文档站上被真正使用**。这不矛盾，但要写清楚：如果以后有人新增一条需要网关保护的路由，`--allowed-group` 的配置范式只在 `docs` 这一条路径上被验证过。

## 3. 本域未覆盖的相邻需求

| 能力 | 为什么不在 A | 在哪 |
|---|---|---|
| 根证书分发到客户端 | 属底座交付，不是身份 | [D3](M0-D-底座与运维.md) |
| LDAP 密码生成与轮换 | 属部署自举 | [D4](M0-D-底座与运维.md) |
| 身份命名规范的正文 | 按最小披露剔除，不随仓库分发 | 已归档，见 [开源合规 §7](../开源合规.md) |
