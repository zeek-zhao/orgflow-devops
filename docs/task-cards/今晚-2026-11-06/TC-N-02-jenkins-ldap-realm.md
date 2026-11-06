# [TC-N-02] Jenkins 切 LDAP realm + 组授权 + realm 回滚预案

> **派工批次**：今晚 2026-11-06（用户 22:36 指令）。
> **本目录只有需求与验收，不含实现代码。** 另一个 AI 读 GitHub 上的这些卡片与挂起的
> Issue，自行建 PR 解决问题；派单方不代写实现。
> 全部归入 **M0**；**M1 #60 冻结**，到 M0 全绿且用户人工确认之后才解锁。
> Issue 是需求真本，卡片与 Issue 冲突时**以 Issue 为准**。

- **Issue**：**#87**（用户「认证使用 ldap」指令归入此单，**不新建重复单**）
- **依赖**：TC-N-01（镜像里必须有 `ldap` 插件，现网 v1 里没有）
- **相关**：TC-N-06 里的 #86（摘网关）、#89（权限矩阵）

## 需求

修掉今天实测的 **403 Authentication required**：完整 OIDC 链走完落到 Jenkins 仍是 anonymous。
把 `config/jenkins.yaml` 的 `securityRealm: local` 切成 LDAP，权限按
`posixGroup.memberUid` 组授权表达。

## 必须正视的事实（用户已裁决）

- **Jenkins JCasC 只能有一个 `securityRealm`**：切 ldap 后本地 `admin/密码` 账号从运行时消失。
  用户选的「admin 兜底」实现为 **组授权 + realm 回滚预案**，不是运行时双 realm、也不是新插件。
- 兜底方案：`svc-platform-admin`（已在 `jenkins-admin` 组）授 Overall/Administer；
  另落一份一键把 JCasC 切回 local realm 的脚本 + 文档；
  `.env` 的 `JENKINS_ADMIN_*` 保留作应急回滚凭据。
- **不新增 LDAP 账号**（保持 10 账号 / uidNumber 1000–1009 基线，`migrate_identity.py --verify` 仍绿）。
- 摘网关（`config/routes.yaml` 里 `jenkins` 的 `auth: true` 移除）归 **#86**，本卡不动；
  顺序上必须 #86 完成后才摘，否则出现登录真空。

## 验收

- [ ] JCasC 重载后用 `svc-platform-admin / 123456` 调 `/whoAmI/api/json` 返回
      `authenticated=true`，且能看到 `jenkins-admin` 组（贴输出）
- [ ] 错口令反证 401；非 `jenkins-admin` 组成员登录后**不得**有 Overall/Administer
- [ ] 完整 OIDC 链走完落到 Jenkins **不再 403**（贴 HTTP 码与页面 title）
- [ ] 回滚预案 dry-run 能生成可执行的 local realm 片段，且**不会自动执行**
- [ ] `migrate_identity.py --verify` 仍绿；线上 LDAP 仍是 33 条 / 10 个新 `uid=` DN

## 禁止事项

- 不得把 LDAP admin 密码写进仓库或日志（用 `${LDAP_ADMIN_PASSWORD}`）
- 不得为了「本地 admin 还能登录」而放弃切 realm（用户已接受单 realm 事实）
- 不得在 #86 完成前先摘网关

## 派工铁律（每张卡都适用）

- 不改 `.env`（`deploy.sh` 有「已有 .env 绝不修改」约定）；凭据只用环境变量 / `withCredentials`。
- 不伪造通过：所有验收必须真跑并贴原始输出、run id、HTTP 码；不许写「应该可以」「预计通过」。
- 不为过测试放宽判据；发现夹具不匹配就**修夹具**，不是删断言。
- 不自行合并 PR；派工分支由派单方 `gh pr merge --rebase` 合并（禁止 squash）。
- author 恒为 `zeek.zhao <zeek.zhao@foxmail.com>`；commit message 含反引号时落文件用 `-F`。
- 不用 `--no-verify` 绕过 pre-push；rebase 后的既有分支换新分支名推送。
- `pre-push` 钩子在既有分支上会误扫 GitHub rebase 的 committer —— 换全新分支名，不是绕钩子。
- 每条关单评论必须附真实证据；**需要人工浏览器验收的项目不许自行关单**。
