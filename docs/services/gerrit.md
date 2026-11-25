# Gerrit 服务手册（M2.1）

> 状态：待部署验证 | 分支 `feat/m2-gerrit-cgit-harbor` | 依据 OrgFlow M2 施工方案 §M2.1

## 1. 职责

代码评审 + Git 服务。LDAP 认证（复用 M1 的 OpenLDAP），Web 走 Caddy `PUB_HTTP_GERRIT` 回环口（Funnel :8443 回源），SSH 发布宿主 `${P_GERRIT_SSH}` 供 tailnet 设备直连（Funnel 不转 TCP，公网不可达 SSH）。

## 2. 镜像与网络

- 镜像：`gerritcodereview/gerrit:3.9.0`（官方镜像，不走自建）。Docker Hub 在本环境被墙，从 `docker.1ms.run` 加速站落地后镜像推 GHCR 并 `@sha256` 钉死。
- 固定 IP `.18`（`IP_GERRIT`），接 `orgflow-minimal_orgflow` 网络。
- 卷：`gerrit_git`（裸库，cgit 只读共享）、`gerrit_etc`（配置与 secure.config）。
- 配置：`services/gerrit/etc/gerrit.config.tmpl` → entrypoint 用 `out/urls.env` 渲染（canonicalWebUrl 等无字面域名），先备份 `.bak`。

## 3. 部署

```bash
# 前置：expand-memory（swap/cgroup）+ 卷预建（up.sh 幂等创建）
bash scripts/expand-memory.sh
make render                       # 生成 out/urls.env
docker volume create orgflow-minimal_gerrit_git
docker volume create orgflow-minimal_gerrit_etc
bash up.sh --only gerrit          # 单起
```

## 4. 初始化（一次性，人工）

1. 首个人类管理员 `zeek.zhao` 首次 LDAP 登录后，手工加入管理员组（在 `All-Projects` 的 `refs/*` 给 LDAP 组 `jenkins-admins` 完整权限）。
2. `Global Capabilities` 给 `jenkins-ci` 授予 `Stream Events`。
3. 建仓 `orgflow-devops`，`HEAD` 指向 `main`；初始内容从 GitHub 镜像导入（`git clone --mirror` + `git push --mirror`），不做空仓起步。

## 5. 验收（文档 §M2.1 判据）

| # | 判据 | 命令 |
|---|---|---|
| 1 | Web 200 | `curl -sSI https://${PUBLIC_HOST}:8443/` |
| 2 | SSH ls-projects | `ssh -p 29418 <user>@<host> gerrit ls-projects` 含 `orgflow-devops` |
| 3 | jenkins-ci clone | `git clone ssh://<host>:29418/orgflow-devops` |
| 4 | 评审流 | `git push HEAD:refs/for/main` 生成 Change |
| 5 | cgit 联动 | 见 cgit.md |
| 6 | 端口互换 | `FUNNEL_PORT_GERRIT=10000` 后 render + funnel 重下发，URL 跟随、旧端口失效 |

## 6. 已知约束（真实状态）

- 镜像拉取受网络限制：仅 `docker.1ms.run` 可用且慢（多次 150~360s 超时），需耐心续拉；拉取完成后必须把真实 manifest digest 回填 `config/images.env` 的 `UPSTREAM_GERRIT` 与 `tests/images.lock` 的 gerrit 行，替换当前占位值。
- 物理内存约 5.x GiB，Gerrit JVM 常驻较大，依赖 8 GiB swap；内存紧张时可能明显换页。
