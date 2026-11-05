# [#84] REQ-M0-A1 身份命名规范转正 + LDIF 数据缺陷修复

- **Issue**：#84（https://github.com/zeek-zhao/orgflow-devops/issues/84）—— **需求真本，冲突时以 Issue 为准**
- **分支**：`fix/84-identity-naming`
- **依赖**：无
- **token 预算**：约 8 万 token；超预算先停下汇报，不要硬推
- **派工批次**：批次 1（并发）

> 卡片正文即派给执行方的 prompt。开工前先读 `docs/AI会话清单.md` 与 `docs/会话交接.md` §0 / §3；需求编号与资料依据见 `docs/M0-增量需求总表.md`。

**本卡特别提示**：只修数据缺陷与规范状态，不改任何 uid 字符串或 DN（那是 #85）。

---
> 需求索引：[M0 增量需求总表](https://github.com/zeek-zhao/orgflow-devops/blob/main/docs/M0-增量需求总表.md) §3 **REQ-M0-A1**；决策背景见 §0，网上资料核证见 §1，213 现状取证见 §2。
> **本 Issue 是需求真本**；执行副本在 `docs/task-cards/`，链路见 `docs/派单流程.md`。
> 里程碑 M0 · Project #5 · 批次 1 · 前置：无

## 目标

`docs/身份命名规范.md` 从草案转为已决策真本并进入 git；LDIF 里与命名无关的硬缺陷（uidNumber 冲突、注释失真、gerrit.anonymous 无组、无盐 MD5）清零。交付后 `make test` 绿、目录数据自洽，但 uid 字符串保持不变。

## 背景与取证

| 事实 | 值 | 来源 |
|---|---|---|
| `admin.jira` 与 `dev.jira` 的 uidNumber 都是 1009 | 冲突 | `services/auth/ldif/users.ldif` |
| users.ldif 头注释写 Total Entries: 9，实际 10 用户 + 1 OU | 失真 | 同上 |
| 口令哈希是无盐 `{MD5}` | `4QrcOUm6Wau+VuBX8g+IPg==` | 同上 |
| app.ldif 两处注释把 `cn=*-admin` 写成 `ou=gerrit` | dn 行本身正确 | `services/auth/ldif/app.ldif` |
| `gerrit.anonymous` 不属于任何组 | 权限悬空 | 同上 |
| 新落盘的 `docs/身份命名规范.md` 未进 README 索引导致 `make test` 红 | 已由 PR #83 修复，本 Issue 复核 | 2026-11-05 实测 |

## 范围

**改**
- `docs/身份命名规范.md`：状态行去掉「草案 / 待确认」
- `services/auth/ldif/users.ldif`：uidNumber 全局唯一化、头注释订正、`{MD5}` → `{SSHA}`（口令值仍 `123456`）
- `services/auth/ldif/app.ldif`：注释订正、`gerrit.anonymous` 归入合适组
- `tests/bats/10_ldap.bats`：加 uidNumber 唯一性断言、条目数断言
- `docs/账号与登录.md`：明文写出初始口令 `123456` 的交付口径

**不新增文件**（规范与总表已由 PR #83 入库）。

## 验收

- [ ] `make test` → 退出码 0
- [ ] `grep -c "{MD5}" services/auth/ldif/users.ldif` → `0`
- [ ] `grep -c "{SSHA}" services/auth/ldif/users.ldif` → 等于用户条目数
- [ ] `awk '/^uidnumber:/{print \$2}' services/auth/ldif/users.ldif | sort | uniq -d` → 空（无重复）
- [ ] 反证：故意把两个 uidNumber 改回相同 → `10_ldap.bats` 必须红；恢复后复绿（贴两次输出）

## 禁止事项

- 不得改 Git author 门禁相关文件：`identity.yml` / hooks / `Makefile identity-check` / `docs/提交规范.md`
- 不得在本 Issue 改任何 uid 字符串或 DN（那是 A2 的范围）
- 不得改 `out/` 下的渲染产物（只改真源）
- 不得为了过测试放宽断言
- 不得自行合并 PR

## 依赖与前置

- [ ] `make test` 绿（PR #83 已修 README 索引基线）
- [ ] 无前置 Issue

## token 预算

约 8 万；超预算先停下汇报，不要硬推。

## 交付物

- [ ] 分支 `fix/84-identity-naming`，提交信息符合 `docs/提交规范.md`
- [ ] PR 正文含：做了什么 / 关键决策与偏离 / 验收实测表 / 未验证项
- [ ] 验收输出原样贴进交付说明（命令 + 真实输出，不要转述）
## 本卡的派工边界（派单方补充，不改动 Issue 需求）

- 在**独立 git worktree** 里工作（`git worktree add /tmp/wt-<issue> -b <分支> origin/main`），
  不改 213 主工作区、不碰运行中的容器、不改 `.env`。
- 禁止执行 `make down -v`、`USE_GHCR=1 make deploy` 以及任何会重启/重建线上栈的命令。
- 提交前跑 `make test`；提交信息符合 `docs/提交规范.md`，author 恒为
  `zeek.zhao <zeek.zhao@foxmail.com>`，不带 AI 署名。
- 本轮**只提交并推送分支，不要开 PR、不要自行合并**（派单方统一 rebase 合并）。
- 交付时报告：分支名、commit hash、`make test` 原样输出、验收条目逐条实测结果、未验证项。

## 交付后的记录

（派单方填，执行方不用填）

- PR：#
- 结果：
- 与本卡的偏离：
