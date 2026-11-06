# [#85] REQ-M0-A2 LDAP 全量重命名与口令迁移（高风险窗口）

- **Issue**：#85（https://github.com/zeek-zhao/orgflow-devops/issues/85）—— **需求真本，冲突时以 Issue 为准**
- **分支**：`feat/85-ldap-rename`
- **依赖**：#84（**已合并**，`f1b5700`；身份命名规范已转正、uidNumber 冲突已清零）
- **token 预算**：约 15 万 token；超预算先停下汇报，不要硬推
- **派工批次**：批次 2（**高风险窗口，单独执行；A3/A4/A5 不得与本卡并行**）

> 卡片正文即派给执行方的 prompt。开工前先读 `docs/AI会话清单.md`、`docs/会话交接.md` §0/§3、
> `docs/身份命名规范.md`（**全量重命名唯一真源，§3 映射表不得另立**）与 `docs/派单流程.md`。

**本卡特别提示**：这是唯一会改动所有服务登录标识的窗口。只做**仓库层 + 可复跑迁移/回滚脚本 + 静态验证**，
**不得在 213 线上 LDAP 直接执行迁移**（线上导入由派单方在授权后单独做）。

## 目标

所有用户 DN 与 uid 按 `docs/身份命名规范.md` §3 完成迁移：用户 DN 统一
`uid=<uid>,ou=users,dc=devops,dc=com`，口令统一 `{SSHA}` / 初始值 `123456`；
Dex / Jenkins / Nexus / phpLDAPadmin / 文档 / 测试里的引用点全部同步，旧 uid 在全库归零。

## 背景与取证（执行方无法自己查到的）

| 事实 | 值 | 来源 |
|---|---|---|
| 当前 DN 是 `cn=<显示名>,...`；Dex `userSearch.username=uid` | DN 与登录标识无关，改显示名就要 modrdn | `out/dex/config.yaml`（**渲染产物，只改真源再重渲染**） |
| Jenkins LDAP 默认 group filter 兼容 `posixGroup.memberUid` | `(\|(member={0})(uniqueMember={0})(memberUid={1}))` | Jenkins LDAP plugin 文档 |
| 线上 LDAP 现状（2026-11-06 17:00 复核） | **33 条**、10 个 `posixAccount`、**无 `rdsw`**（已按裁决清除） | admin 绑定 ldapsearch（见下条铁律） |
| **LDAP 判据铁律** | 匿名 `-x` 的 `scope=2` 被 ACL 伪装成 `32 No such object` / 0 条，**不是「目录空」**；必须用 `-D "cn=admin,dc=devops,dc=com" -w "$LDAP_ADMIN_PASSWORD"` 显式绑定 | 2026-11-06 实测：`docker logs of-ldap` 中 admin 绑定 `scope=0` 为 `err=0 nentries=1`，匿名 `scope=2` 为 32 |
| `rdsw` 归属 | **已裁决：彻底清除**（2026-11-06，仓库 + 线上 LDAP 均已清）。本卡按 **10 个 uid** 迁移，不得再引入 `rdsw` | `docs/M0-增量需求总表.md` §0 A |
| Git author 门禁 | `zeek.zhao <zeek.zhao@foxmail.com>` 是独立硬门槛，与 LDAP uid `zeek.zhao` 同名只是巧合 | `docs/提交规范.md`、`identity.yml` |

## 范围

**改**
- `services/auth/ldif/users.ldif`、`app.ldif`：按 §3 映射表全量改名 + 改 DN + uidNumber 连续化
- `services/auth/dex/` 模板（若有 uid 引用）；`out/dex/config.yaml` 由真源重渲染，不手改
- `tests/bats/10_ldap.bats` 及其他 uid 断言（注意当前断言是 33 条 / 10 个 posixAccount）
- `docs/账号与登录.md`、`docs/身份命名规范.md` 状态、Windows 侧 `orgflow-hosts.bat creds` / `orgflow-login.ps1` 账号说明

**新增**
- `scripts/` 下迁移脚本 + 回滚 LDIF（可复跑、可回退）、`scripts/` 下静态一致性校验脚本

## 验收

- [ ] `ldapsearch -x -H ldap://localhost -D 'cn=admin,dc=devops,dc=com' -w "$LDAP_ADMIN_PASSWORD" -b 'ou=users,dc=devops,dc=com' '(objectClass=posixAccount)' uid` 列出的 uid 与规范 §3 完全一致（**线上导入未授权时，此项降级为对 LDIF 文件做等价静态校验并明确标注未验证**）
- [ ] 脚本校验每个 `posixGroup.memberUid` 都能解析到存在的 uid（贴输出）
- [ ] `grep -r` 旧 uid 在 `docs/` `config/` `services/` `tests/` 中归零（贴命令与 0 行输出）
- [ ] `make test` 退出码 0（贴原样输出）
- [ ] 反证：保留一个旧 uid 引用 → 全库 grep 必须报出该文件与行号；删掉后归零（贴两次输出）
- [ ] 反证：往 `app.ldif` 塞一个不存在的 `memberUid` → 校验脚本必须红；恢复复绿

## 禁止事项

- 不得在 213 线上容器直接 `ldapmodify` 而不留回滚 LDIF；**本轮一律不碰线上 LDAP**
- 不得在 A3/A4/A5 未就绪时把生产入口切到新 uid
- 不得改 Git author 门禁相关文件（`identity.yml` / pre-commit / pre-push / `Makefile identity-check` / `docs/提交规范.md`）
- 不得执行 `down -v`（会重建 Caddy 内部 CA，Windows 客户端证书全失效）
- 不得为了过测试放宽断言：断言是需求的一部分
- 不得自行合并 PR

## 依赖与前置

- [ ] 前置 Issue #84 已合并（`git log --oneline origin/main | grep f1b5700` 有输出）
- [ ] `docs/身份命名规范.md` §3 映射表存在且状态为「已决策真本」
- [ ] 需要人工动作（**本轮不做，列为未验证项**）：迁移前由派单方导出完整 LDIF 备份到 `~/backup/`
## 本卡的派工边界（派单方补充，不改动 Issue 需求）

- 在**独立 git worktree** 里工作，不改 213 主工作区、不碰运行中的容器、不改 `.env`。
- 禁止执行 `make down -v`、`USE_GHCR=1 make deploy` 以及任何会重启/重建线上栈的命令。
- 提交前跑 `make test`；提交信息符合 `docs/提交规范.md`，author 恒为
  `zeek.zhao <zeek.zhao@foxmail.com>`，不带 AI 署名。
- 本轮**只提交并推送分支，不要开 PR、不要自行合并**（派单方统一 rebase 合并）。
- 交付时报告：分支名、commit hash、`make test` 原样输出、验收条目逐条实测结果、未验证项。
- 基线：以开工时 `origin/main` 为准（本卡落库时 = `2f5bf23`）。开工前必须 `git fetch origin --prune` 复核并记录实际 sha；若已前进，停下汇报，不要自行 rebase。

## 交付后的记录

（派单方填，执行方不用填）

- PR：**#107**（`9f52f39` → main `155b4407`）；执行方为派单方手工（子代理派工 429）。
- 结果：10 个 uid 与 DN 全量迁移、21 处 `memberUid` 重写、新增 `scripts/migrate_identity.py`（`--check` / `--apply` / `--rollback-ldif` / `--verify`）、6 份运行真本文档同步、`--verify` 纳入 `make test`；`make test` RC=0，两条反证绿/红/红/绿。Issue 已关单、Project 置 Done。
- 与本卡的偏离：按派工边界只做仓库侧；线上切换由派单方另行执行，最终按用户裁决以「不备份 + 删卷重建」完成（见下节）。

## 线上切换记录（派单方，2026-11-06 18:20）

**用户裁决**：不需要备份，把 LDAP 改完以后删除、再重新部署 —— 覆盖本卡「只做仓库侧、必须带回滚 LDIF、不碰线上」的边界。

**切换前预演救了一次事故**：独立空卷容器导入真 LDIF，`ldapwhoami` 只有 2/10 成功。根因是 `{SSHA}` base64 里的 `+` 被写成 `\+`，`ldapadd` 不还原反斜杠；**PR #112**（`d35cf1c`）修 10 处并新增 `scripts/test_ldif_passwords.py` 纳入 `make test`。修后预演 10/10 才动生产卷。

**执行**：`docker compose stop ldap` → `rm -f ldap` → `volume rm orgflow-devops_ldap_data orgflow-devops_ldap_config` → `up -d --no-deps ldap` → `bootstrap-ldif.sh` → 重启 dex / ldapadmin / oauth2-proxy。全程未做任何备份。

**线上验收**：33 条 / 10 个 `posixAccount` / DN 全为 `uid=` / `uidNumber` 1000–1009 / `displayName` 10/10 / 旧 uid 与 `rdsw` 0 处 / 21 处 `memberUid` 无悬空 / 10 个账号 `ldapwhoami -w 123456` 全成功 / Dex `userSearch` 与 `groupSearch` 命中。OIDC 跳转链与 LDAP 认证也已真跑通（错误口令 401、正确口令进入授权确认页并拿到会话 cookie）；Jenkins 侧 403 是 `securityRealm: local` 的既有缺口，归 #87。

**残留**：`out/backups/` 里 6 个旧 LDAP 包仍是旧 uid，按裁决未新建备份；`verify-ldap` 会真恢复并把线上静默回滚，需单独处理。
