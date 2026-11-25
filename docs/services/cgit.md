# cgit 服务手册（M2.1）

> 状态：已部署 + 白名单加固（2026-11-26 复核） | 分支 `feat/m2-gerrit-cgit-harbor` | 依据 OrgFlow M2 施工方案 §M2.1

## 1. 职责

Gerrit 裸库的只读 Web 视图（cgit），公网经 Caddy `:443` 的 `/cgit/` 路径前缀暴露。代码匿名只读（文档已定稿，若要锁加 Caddy `basic_auth`）。

## 2. 镜像与网络

- 镜像：`orgflow/m1-cgit:ctx-c3b8b5ce7f39`（自建，内容哈希 tag）。`Dockerfile` = `ubuntu:24.04@sha256:fe8156…` + `cgit fcgiwrap nginx-light`；`user 1000:1000`（须与 Gerrit 容器 uid 对齐，否则读不到裸库）。
- 固定 IP `.19`，只读挂载 `gerrit_git:/var/gerrit/git:ro`，不发布宿主端口。
- 内容哈希 `c3b8b5ce7f39…`（`scripts/image-hash.sh cgit`），登记于 `tests/images.lock`；改 Dockerfile/cgitrc/entrypoint/nginx 配置后必须 `make images-hash` 并同步 images.env/compose/tag 四处。
- 2026-11-26：cgitrc/entrypoint 白名单加固后哈希从 `25f3b21d…` 变为 `c3b8b5ce…`，CI（mirror-m2.yml）按 `services/cgit/**` 变更自动重建并推 GHCR 新 tag。

## 3. 关键配置

- `cgitrc`：`virtual-root=/cgit/`（对齐公网路径）、**`project-root=/var/gerrit/git` + `project-list=/tmp/projects.list` 白名单**（不用 `scan-path`，见下）、`enable-http-clone=1`。
- `projects.list`：写在 `/tmp/projects.list`（裸库目录只读），由 `entrypoint.sh` 冷启生成 + 每 5 分钟刷新，亦可由 Jenkins 定时 Job（`scripts/cgit-refresh.sh`，待 M2.4）刷新。
- **白名单（安全加固，2026-11-26）**：原 `scan-path=/var/gerrit/git` 会扫全目录，把 `All-Users.git`（存用户 SSH key/配置/邮箱）也公开，属安全泄露。改为 `project-root` + `project-list`，entrypoint `refresh_list` 仅列业务仓，排除 `All-Projects.git`/`All-Users.git`（可用 `CGIT_EXCLUDE` 覆盖）。精确匹配，名字含 `All-Users` 子串的业务仓不被误伤。

## 4. 部署

```bash
bash up.sh --only cgit             # 依赖 gerrit_git 卷存在（up.sh 幂等预建）
```

## 5. 验收（文档 §M2.1 判据 5）

- `curl -sSI https://${PUBLIC_HOST}/cgit/` → 200 且列表非空（导入仓库后）。
- **空态边界（2026-11-26 复核）**：白名单模式下，当前无业务仓时 `project-list` 为空，cgit 对空列表返回 **404**（旧 `scan-path` 方案之所以显示 200，是因为它错误地把 `All-Projects.git`/`All-Users.git` 系统库当业务仓列出）。这是"无业务仓"既有待办的直接后果，非白名单缺陷；导入首个业务仓后 `/cgit/` 自动恢复 200。未加 error_page 兜底——那会把真实 404 伪装成 200，掩盖问题。
- 白名单：`cat /tmp/projects.list`（容器内）应只含业务仓，不含 `All-Users.git`。
- `git clone https://${PUBLIC_HOST}/cgit/orgflow-devops.git` → 成功。
- **clone 协议（待修复）**：当前 Caddy `handle_path /cgit/*` 剥前缀可能破坏 smart-http 路径；`curl /cgit/<repo>.git/info/refs?service=git-upload-pack` 返回 text/html（cgit 页面）而非 `application/x-git-upload-pack-advertisement`。属差距清单待办，未虚报通过。
