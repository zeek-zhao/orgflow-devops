# [TC-N-03] Jenkins 面板分类、SSH 双节点接入与 Ansible 远程部署占位

> **派工批次**：今晚 2026-11-06（用户 22:36 指令）。
> **本目录只有需求与验收，不含实现代码。** 另一个 AI 读 GitHub 上的这些卡片与挂起的
> Issue，自行建 PR 解决问题；派单方不代写实现。
> 全部归入 **M0**；**M1 #60 冻结**，到 M0 全绿且用户人工确认之后才解锁。
> Issue 是需求真本，卡片与 Issue 冲突时**以 Issue 为准**。

- **Issue**：**#116**（需求真本）
- **依赖**：TC-N-01（插件）；节点复用现有 agent 密钥体系，可并行开发
- **用户裁决**：外部依赖**只留占位**，不接真实 Gerrit / 远程主机

## 需求

1. **任务分类面板**：双维度 ListView，**不移动 Job、不用 Folder**（Folder 会改 Job 路径、丢构建历史）。
   - 按动作：`部署`、`备份与恢复`、`验证`、`Nexus`
   - 按服务：`jenkins`、`ldap-auth`、`nexus`
   用 `includePattern` 正则归类，`primaryView` 设总览；由 JCasC 声明，重部署后仍在。
2. **子节点不同接入方式**（歧义已裁决为「Ansible + 两种 SSH 节点」）：
   - 「SSH 预接入」：`orgflow-ssh-static`，预置密钥的静态 SSH 节点
     （复用 `jenkins-agent-ssh` 凭据与 `manuallyProvidedKeyVerificationStrategy` 的固定 host key）
   - 「SH 单核介入」：`orgflow-ssh-single`，同 launcher 但 `numExecutors: 1`、独立 label
   两者都必须**真正在线**，不是只写进 JCasC。
3. **远程部署**：Python 部署工具按 **Ansible** 理解，仓库内落 inventory 占位 + 幂等 playbook + README；
   本机 `ansible-playbook --check` dry-run 真跑一次。**不接真实目标主机**。
4. `gerrit-trigger` 插件已在 TC-N-01 装好，本卡**只补文档声明「未接 Gerrit 端点」**。

## 现状（见总览 README）

只有 `all` 一个视图、16 个 Job（仅 3 个有过构建）；节点只有 Built-In + `orgflow-docker`
（2 executors）。`secrets/` 只有 agent SSH key 对，`.env` 无 ANSIBLE/GERRIT 变量。

## 验收

- [ ] `/api/json?tree=views[name,url]` 列出 7 个新视图，每个视图 **Job 数 > 0**（贴输出）
- [ ] `/computer/api/json` 两个新节点 `offline=false`，各触发一次最小构建并成功
- [ ] `ansible-playbook --check` 真跑一次并贴输出；README 明写「未接真实目标主机」
- [ ] JCasC 重载后视图与节点仍存在（不是 UI 手点）
- [ ] 文档里「Gerrit 未接端点」「远程部署未接真实主机」两处声明可见

## 禁止事项

- 不得虚构 Gerrit webhook / 远程部署成功
- 不得把目标主机 IP、私钥写进仓库；不得改 `.env`
- 不得新增 LDAP 账号

## 派工铁律（每张卡都适用）

- 不改 `.env`（`deploy.sh` 有「已有 .env 绝不修改」约定）；凭据只用环境变量 / `withCredentials`。
- 不伪造通过：所有验收必须真跑并贴原始输出、run id、HTTP 码；不许写「应该可以」「预计通过」。
- 不为过测试放宽判据；发现夹具不匹配就**修夹具**，不是删断言。
- 不自行合并 PR；派工分支由派单方 `gh pr merge --rebase` 合并（禁止 squash）。
- author 恒为 `zeek.zhao <zeek.zhao@foxmail.com>`；commit message 含反引号时落文件用 `-F`。
- 不用 `--no-verify` 绕过 pre-push；rebase 后的既有分支换新分支名推送。
- `pre-push` 钩子在既有分支上会误扫 GitHub rebase 的 committer —— 换全新分支名，不是绕钩子。
- 每条关单评论必须附真实证据；**需要人工浏览器验收的项目不许自行关单**。
