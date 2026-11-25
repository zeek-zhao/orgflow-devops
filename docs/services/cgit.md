# cgit 服务手册（M2.1）

> 状态：待部署验证 | 分支 `feat/m2-gerrit-cgit-harbor` | 依据 OrgFlow M2 施工方案 §M2.1

## 1. 职责

Gerrit 裸库的只读 Web 视图（cgit），公网经 Caddy `:443` 的 `/cgit/` 路径前缀暴露。代码匿名只读（文档已定稿，若要锁加 Caddy `basic_auth`）。

## 2. 镜像与网络

- 镜像：`orgflow/m1-cgit:ctx-e63757ae774e`（自建，内容哈希 tag）。`Dockerfile` = `ubuntu:24.04@sha256:fe8156…` + `cgit fcgiwrap nginx-light`；`user 1000:1000`（须与 Gerrit 容器 uid 对齐，否则读不到裸库）。
- 固定 IP `.19`，只读挂载 `gerrit_git:/var/gerrit/git:ro`，不发布宿主端口。
- 内容哈希 `e63757ae774e…`（`scripts/image-hash.sh cgit`），登记于 `tests/images.lock`；改 Dockerfile/cgitrc/entrypoint/nginx 配置后必须 `make images-hash` 并同步 images.env/compose/tag 四处。

## 3. 关键配置

- `cgitrc`：`virtual-root=/cgit/`（对齐公网路径）、`scan-path=/var/gerrit/git`、`enable-http-clone=1`。
- `projects.list`：写在 `/tmp/projects.list`（裸库目录只读），由 `entrypoint.sh` 冷启生成 + 每 5 分钟刷新，亦可由 Jenkins 定时 Job（`scripts/cgit-refresh.sh`，待 M2.4）刷新。

## 4. 部署

```bash
bash up.sh --only cgit             # 依赖 gerrit_git 卷存在（up.sh 幂等预建）
```

## 5. 验收（文档 §M2.1 判据 5）

- `curl -sSI https://${PUBLIC_HOST}/cgit/` → 200 且列表非空（导入仓库后）。
- `git clone https://${PUBLIC_HOST}/cgit/orgflow-devops.git` 成功。
