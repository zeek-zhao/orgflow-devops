# orgflow-devops（M0 最小 DevOps 底座）

一套从零构建的最小 DevOps 底座：7 个服务、**单域名路径型**统一入口、内部 CA、统一身份、配置即代码。

- **逐服务 compose**：每个服务一个 `services/<svc>/compose.yml`，`up.sh` 按依赖顺序启动（dnsmasq → certs-init → caddy → ldap → ldapadmin → homepage → router）。
- **镜像全部本分支构建**：6 个 Dockerfile 真薄封装（官方上游 `@sha256` digest 固定 + 配置/图标/license 打进镜像），`certs-init` 复用 router。本机构建为准（`scripts/build-images.sh`）；CI 在有推送权限时可推 GHCR 出 digest artifact。
- **单域名路径型入口**：HomePage 占根 `/`，`/ldapadmin/`、`/router/`、`/status` 走路径前缀；Tailscale Funnel 在边缘终止 TLS 后回源 Caddy `:PUBLIC_PORT`。无子域 vhost。
- **配置即代码**：域名/端口用占位符（`.env` 的 `DOMAIN`/`PUBLIC_HOST`），`check-domain.sh` 门禁；路由单一真源 = `config/Caddyfile` 骨架 + `config/routes.yaml` 片段，router 合成后 reload，输出即实跑。
- 集成分支 `feat/m0-v2`；一个任务 = 一个 Issue = 一个 PR（T1~T8 修复轮、T9~T12 M0-v3），`main` 仅作写法参考。

## 镜像模式（默认 GHCR digest）

**线上默认走 GHCR `@sha256` digest 镜像**（`USE_LOCAL_IMAGES=0`，零停机、不依赖本地是否构建过）。本地自建镜像是可选模式，**默认关闭**，须显式开启且满足前置校验：

| 模式 | 开关 | 注入配置 | 生效镜像 |
|---|---|---|---|
| **默认（线上）** | `USE_LOCAL_IMAGES=0` | 仅 `config/defaults.env` | GHCR `@sha256` digest |
| **本地自建** | `USE_LOCAL_IMAGES=1` | defaults + `config/images.env`（后者覆盖） | `orgflow/m0-*:v2`（须 lock 无 PENDING 且本地镜像存在，否则告警回退 GHCR） |

> 不要把 `orgflow/m0-*` 写进 `defaults.env`（会让默认路径依赖本地构建状态）。详见 `docs/运维/镜像与供应链.md` §3.5；`./up.sh --dry-run` 可查看实际解析镜像。

## 快速开始

```bash
cp .env.example .env            # 填 DOMAIN / PUBLIC_HOST / 端口
bash scripts/build-images.sh    # 本机构建镜像（默认回退已验证 GHCR 镜像，零停机）
./up.sh                         # 顺序启动 7 服务（默认不 force-recreate，存量 baseline 不动）
./status.sh                     # 只读状态（含配置指纹 FP 列）
make routes                     # 改 config/routes.yaml 后渲染并 reload
make check && make test         # 门禁与静态自检
```

## 文档

- 架构与入口：`docs/架构.md`、`docs/运维/路由注册.md`
- 服务手册：`docs/services/*.md`
- 验收与记录：`docs/records/`（执行日志、验收矩阵、变更台账、截图清单）
- 使用说明：`docs/使用说明.md`

> 本分支从零实现，`main` 仅作参考。工作区规范、禁止事项见 `docs/运维/` 与修复轮文档。
