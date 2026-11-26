# Gerrit 人工使用指南（面向写代码的人）

> 状态：适用 | 最后核对：2026-11-26 | 对应分支 `feat/m2-gerrit-cgit-harbor`（M2.4 Phase2）
> 面向对象：需要把代码推上来、参与评审的工程师。部署/运维细节见 [services/gerrit.md](../services/gerrit.md)。

本文所有公网地址都从 `out/urls.env` 读取，**禁止写死域名/端口**；文中不出现任何真实口令，凡口令一律写「管理员发放」。开始前先加载：

```bash
set -a; source out/urls.env; set +a
echo "$URL_GERRIT"   # Gerrit Web（Funnel :8443）
echo "$URL_CGIT"     # cgit 只读浏览
```

## 1. 登录与改密码（LDAP）

Gerrit 复用 OpenLDAP 账号，首次用 LDAP 用户名/口令登录 Web 即自动建号（`zeek.zhao` 这类首个登录者自动进 `Administrators`）。

1. 浏览器打开 `$URL_GERRIT`，用**管理员发放的 LDAP 用户名与口令**登录。
2. 改口令请到 LDAP 管理页 `$URL_ENTRY/ldapadmin/`（凭据同样由管理员发放），不要在 Gerrit 里改——Gerrit 侧不存口令。
3. 登录后在右上角 `Settings → HTTP Password → Generate Password` 生成一把 **HTTP 口令**（供 HTTP Basic / REST 用）。这把口令与 LDAP 口令不同，且只显示一次，妥善保存。

## 2. 配置 SSH key（推送代码必需）

Gerrit 的 SSH 服务在宿主 `29418` 端口发布（`P_GERRIT_SSH`），走 tailnet 直连；**Tailscale Funnel 不转发 TCP，公网无法走 SSH**，remote 设备需先接入 tailnet。

### 方式 A：网页添加（推荐）

1. 本地生成密钥对（已有可跳过）：
   ```bash
   ssh-keygen -t ed25519 -C "你的邮箱"
   ```
2. 复制公钥 `~/.ssh/id_ed25519.pub` 全文。
3. Gerrit Web → `Settings → SSH Public Keys → Add New Key`，粘贴保存。

### 方式 B：REST 添加

用第 1 节生成的 HTTP 口令，走 `out/urls.env` 的 `BACKEND_GERRIT`（或 `$URL_GERRIT`）：

```bash
# HTTP 口令由管理员/自己在 Settings 生成，此处用占位变量，不写明文
read -rsp 'Gerrit HTTP password: ' HTTP_PASS; echo
curl -u "$GERRIT_USER:$HTTP_PASS" \
  -H 'Content-Type: text/plain' \
  --data-binary @"$HOME/.ssh/id_ed25519.pub" \
  "$BACKEND_GERRIT/a/accounts/self/sshkeys"
```

### 验证 SSH 连通

```bash
ssh -p "$P_GERRIT_SSH" "$GERRIT_USER@$PUBLIC_HOST" gerrit ls-projects
```
> 首次连接会校验 host key；宿主公钥已随底座固定在 `config/jenkins/known_hosts`。本机可用 `ssh-keyscan -p "$P_GERRIT_SSH" "$PUBLIC_HOST" >> ~/.ssh/known_hosts` 录入。

## 3. HTTP / 匿名只读

- 匿名只读：`$URL_GERRIT` 的 Web 与 Git HTTP 端点（`/orgflow-devops.git/info/refs?service=git-upload-pack`）无需登录即可浏览/克隆。
- 推送需认证：SSH key（第 2 节）或 HTTP 口令。
- cgit 只读浏览在 `$URL_CGIT`，无需登录，适合快速看历史/树。

## 4. 标准工作流：clone → commit → push

```bash
set -a; source out/urls.env; set +a

# 1) clone（SSH；$GERRIT_USER 为你的 LDAP 用户名）
git clone "ssh://$GERRIT_USER@$PUBLIC_HOST:$P_GERRIT_SSH/orgflow-devops"
cd orgflow-devops

# 2) 安装 commit-msg hook——自动生成合法 Change-Id，没有它 push 会被拒
git commit --amend --no-edit          # 若尚未 commit；或正常 git commit
curl -o .git/hooks/commit-msg \
  "$BACKEND_GERRIT/tools/hooks/commit-msg"
chmod +x .git/hooks/commit-msg
git commit --amend --no-edit          # 让 hook 给当前提交补上 Change-Id

# 3) push 到评审分支（不是 main！改 main 会被拒绝）
git push origin HEAD:refs/for/main
```

推送成功后 Gerrit 会给出 change 号（如 `refs/for/main` → change #N）。同一 Change-Id 再次 push 会生成该 change 的**新 patchset**，而不是新 change。

**铁律**：不要 `git push origin main`（直接改 `main` 被禁）；每次改动都用 `refs/for/main` 走评审。

## 5. 网页 Review / Submit

1. 打开 `$URL_GERRIT` → `Changes → Open`，找到你的 change。
2. -reviewer 添加评审人，对方在网页看 diff、行内评论。
3. **Code-Review**：由人手工投（+1/-1/-2）；**Verified**：只归 `ci-bot`（CI 构建成功后自动 +1，失败不回写），人工不要投 Verified。
4. 触发链：push patchset → gerrit-trigger 唤醒 Jenkins `build-from-gerrit` → BuildKit 构建并推 registry → 校验 manifest → ci-bot 回写 Verified +1。
5. 满足提交规则（Code-Review +2、Verified +1 等）后点 `Submit` 合入 `main`。

> 评审流已由功能级 Job `verify-gerrit-review-flow` 自动验证（建探针 change → 触发构建 → Verified +1 → abandon）。

## 6. cgit 浏览

`$URL_CGIT` 提供 `main` 源码的只读 Web 浏览（树、提交历史、diff、raw 文件），无需登录。适合快速确认某文件当前内容，不用来改代码。

## 7. 常见故障

| 现象 | 原因 | 处理 |
|---|---|---|
| push 报 `missing Change-Id in commit message footer` | 没装 commit-msg hook | 按 §4 装 hook 后 `git commit --amend` 补 Change-Id |
| push 报 `publickey` / `Permission denied (publickey)` | SSH key 未录入或用了错误用户 | 确认公钥已加到 Settings → SSH Public Keys；`ssh -p $P_GERRIT_SSH $GERRIT_USER@$PUBLIC_HOST` 自测 |
| HTTP/REST 报 401/403 | 用了 LDAP 口令而非 HTTP 口令，或未加 Basic | 用 Settings 生成的 HTTP 口令 + `curl -u` |
| 网页能开但 SSH 连不上 | Funnel 不转发 TCP，公网不可达 SSH | 接入 tailnet 后用 `$PUBLIC_HOST:$P_GERRIT_SSH`；remote 设备先连 Tailscale |
| push 到 `main` 被拒 | 直推 main 被禁 | 改推 `HEAD:refs/for/main` 走评审 |
| Verified 一直是 0 | 构建失败（不回写）或 change 未触发 | 看 Jenkins `build-from-gerrit` 构建日志；CI 成功才会自动 +1 |
| host key 校验失败 | host key 变更或本机 known_hosts 陈旧 | 重新 `ssh-keyscan -p $P_GERRIT_SSH $PUBLIC_HOST >> ~/.ssh/known_hosts` |

## 8. 变量速查

变量定义见 `out/urls.env` 与 `config/defaults.env`：

| 变量 | 含义 |
|---|---|
| `PUBLIC_HOST` | 公网入口域名 |
| `URL_GERRIT` | Gerrit Web（`https://$PUBLIC_HOST:8443`） |
| `URL_CGIT` | cgit 只读浏览 |
| `BACKEND_GERRIT` | Gerrit 回环后端（REST 用） |
| `P_GERRIT_SSH` | Gerrit SSH 端口（29418） |
| `GERRIT_USER` | 你的 LDAP 用户名（本地自设，如 `zeek.zhao`） |
