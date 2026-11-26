# cgit 服务手册（M2.1）

> 状态：已部署 + 白名单加固（2026-11-26 复核） | 分支 `feat/m2-gerrit-cgit-harbor` | 依据 OrgFlow M2 施工方案 §M2.1

## 1. 职责

Gerrit 裸库的只读 Web 视图（cgit），公网经 Caddy `:443` 的 `/cgit/` 路径前缀暴露。代码匿名只读（文档已定稿，若要锁加 Caddy `basic_auth`）。

## 2. 镜像与网络

- 镜像：`orgflow/m2-cgit:ctx-e0643a8c475e`（自建，内容哈希 tag；M2.2 P1-3 由 m1 统一为 m2，hash 后缀不变）。`Dockerfile` = `ubuntu:24.04@sha256:fe8156…` + `cgit fcgiwrap nginx-light git`；`user 1000:1000`（须与 Gerrit 容器 uid 对齐，否则读不到裸库）。
- 固定 IP `.19`，只读挂载 `gerrit_git:/var/gerrit/git:ro`，不发布宿主端口。
- 内容哈希 `e0643a8c475e…`（`scripts/image-hash.sh cgit`），登记于 `tests/images.lock`；改 Dockerfile/cgitrc/entrypoint/nginx 配置后必须 `make images-hash` 并同步 images.env/compose/tag 四处。
- 2026-11-26 迭代：① 白名单初版 `project-root`+`project-list` 哈希 `c3b8b5ce…`；② smart-http clone 修复（Dockerfile 加 `git`、nginx 加 `git-http-backend` location）→ `b95e2a13d3b6…`；③ **白名单机制纠正**：`project-list` 单独使用实测无效，改 `repo.` 显式清单（`include=/tmp/projects.conf`）→ `e0643a8c475e…`。CI（mirror-m2.yml）按 `services/cgit/**` 变更自动重建并推 GHCR 新 tag。

## 3. 关键配置

- `cgitrc`：`virtual-root=/cgit/`（对齐公网路径）、**`include=/tmp/projects.conf`（`repo.` 显式清单白名单）**（不用 `scan-path`/`project-list`，见下）、`enable-http-clone=1`。
- `/tmp/projects.conf`：由 `entrypoint.sh` 冷启生成 + 每 5 分钟刷新，格式为 `repo.url=<name>` + `repo.path=<GIT_ROOT>/<name>.git`；亦可由 Jenkins 定时 Job（`scripts/cgit-refresh.sh`，待 M2.4）刷新。
- **白名单（安全加固 + 机制纠正，2026-11-26）**：原 `scan-path=/var/gerrit/git` 会扫全目录，把 `All-Users.git`（存用户 SSH key/配置/邮箱）也公开，属安全泄露。初版改 `project-root`+`project-list`，但**实测 cgit 1.2.3 单独使用 `project-list` 返回 "No repositories found"（它是 scan-path 的缓存输出，不是独立输入白名单）**，即使有业务仓也 404。最终改用 `repo.` 显式清单：entrypoint `refresh_list` 扫裸库后排除 `All-Projects.git`/`All-Users.git`（可用 `CGIT_EXCLUDE` 覆盖），逐仓生成 `repo.url`/`repo.path`，cgitrc `include` 引入。端到端验证：有业务仓时 `/cgit/` 返回 200 且只列业务仓。精确匹配，名字含 `All-Users` 子串的业务仓不被误伤。

## 4. 部署

```bash
bash up.sh --only cgit             # 依赖 gerrit_git 卷存在（up.sh 幂等预建）
```

## 5. 验收（文档 §M2.1 判据 5）

- `curl -sSI https://${PUBLIC_HOST}/cgit/` → 200 且列表非空（导入仓库后）。
- **空态边界（2026-11-26 复核）**：`repo.` 显式清单模式下，无业务仓时清单为空，cgit 返回 **404**。2026-11-26 已建首个业务仓 `orgflow-devops`（见下），`/cgit/` 恢复 200。未加 error_page 兜底——那会把真实 404 伪装成 200，掩盖问题。
- **已建业务仓（2026-11-26）**：经 Gerrit Web（BROWSE → Repositories → CREATE NEW）建 `orgflow-devops`，默认分支 `main`。裸库卷 `/var/gerrit/git/orgflow-devops.git` 已生成，cgit 清单含该仓、不含 All-*。REST `GET /projects/?d` 可见（state ACTIVE）。
- 白名单：`cat /tmp/projects.conf`（容器内）应只含 `repo.url=<业务仓>`/`repo.path=…`，不含 `All-Users.git`。
- `git clone https://${PUBLIC_HOST}/cgit/orgflow-devops.git` → 成功。
- **clone 协议（2026-11-26 已修复 + 端到端验证）**：根因不是 Caddy 剥前缀，而是 nginx 把 `info/refs`/`git-upload-pack` 也交给 `cgit.cgi`（它只做 Web 浏览，不处理 git 传输协议）→ 返回 text/html。修复：`Dockerfile` 加装 `git`（提供 `/usr/lib/git-core/git-http-backend`），`nginx-cgit.conf` 增 `location ~ ^/.+\.git/(info/refs|git-upload-pack)$` 转给 backend 并设 `GIT_PROJECT_ROOT=/var/gerrit/git`、`GIT_HTTP_EXPORT_ALL=1`、`PATH_INFO=$uri`。用一次性容器（挂载宿主机 git-core + 临时裸库）实测：`info/refs?service=git-upload-pack` → `200 application/x-git-upload-pack-advertisement`，`git clone` 成功。**待 CI 构建推 GHCR 新 tag `ctx-e0643a8c475e` 后用 `up.sh --recreate cgit` 上线**（本地沙箱 apt 源不可达，无法自构建）。生产裸库属主 gerrit(uid1000) 与 cgit 一致，无 dubious ownership 风险。
