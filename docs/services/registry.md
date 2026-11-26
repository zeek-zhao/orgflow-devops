# registry 服务手册（M2.2 轻量镜像仓库）

> 状态：骨架已落地，镜像待 CI 构建上线 | 最后核对：2026-11-26 | 对应分支：feat/m2-gerrit-cgit-harbor

## 1. 职责与边界

Docker Distribution `registry:2` + htpasswd 基础鉴权，提供 OCI/Docker 镜像的 push/pull 与 `/v2/` API。

- **提供**：镜像 push/pull、`/v2/` 版本探测、单用户 htpasswd（bcrypt）基础鉴权、数据卷持久化。
- **不提供**（M2.2 范围外）：Web UI、项目/成员管理、robot 账号、复制策略、漏洞扫描。需要这些能力时再评估官方文档给出的 A 路线（Harbor 全栈）。

选型依据：本沙箱可用内存约 3.7GiB，官方 Harbor 6 容器 + PG/Redis 会造成 swap 抖动、冷启动慢；
registry:2 轻量方案符合 `config/preflight.sh` 资源闸门「available < 8GiB 建议降级 registry:2」与 gerrit.md §8 的建议。

## 2. 端口与入口

| 层 | 地址 |
|---|---|
| 容器 | `registry:5000`（`P_REGISTRY_HTTP`） |
| 宿主回环 | `127.0.0.1:18086`（`PUB_HTTP_HARBOR`，Funnel 回源目标） |
| 公网 | `https://orgflow-sandbox.tail0b7621.ts.net:10000`（`FUNNEL_PORT_HARBOR`） |

不经 Caddy：Registry `/v2/` 协议对路径前缀/重定向敏感，独立端口直连最稳。Funnel 边缘终止 TLS 后回源 18086。

## 3. 镜像与供应链

- 薄封装：`FROM registry:2@<digest>` + `apache2-utils`（提供 htpasswd）。
- 上游 digest：CI `docker pull registry:2` 取 RepoDigests 产出，回填 `UPSTREAM_REGISTRY`（config/images.env）、
  `tests/images.lock`、`docs/运维/镜像与供应链.md`；Dockerfile 的 FROM 占位 digest 由 CI build 前 sed 注入。
- tag：`orgflow/m2-registry:ctx-04446f23aa73`（= `image-hash.sh registry` 前 12 位），由 CI 推 GHCR
  `ghcr.io/zeek-zhao/orgflow-devops/m2-registry:<tag>`，国内经 `ghcr.nju.edu.cn` 代理拉取。

## 4. 凭据与初始化

- `REGISTRY_USER` / `REGISTRY_PASSWORD` 经 env 注入（默认 admin/change-me，生产须在 `.env` 改强口令）。
- entrypoint 用 `htpasswd -B -b` 渲染到卷 `/auth/htpasswd`（600），幂等（同名用户先删后加），不入库/不进 git。
- 客户端：`docker login orgflow-sandbox.tail0b7621.ts.net:10000` 后 push/pull。

## 5. 卷与固定 IP

- 数据卷 `orgflow-minimal_registry_data`（`/var/lib/registry`）、鉴权卷 `orgflow-minimal_registry_auth`（`/auth`）。
- 固定 IP `192.168.90.20`（`IP_REGISTRY`），网络 `orgflow-minimal_orgflow`。

## 6. 已知约束

- 单用户 htpasswd，无项目隔离；如要多成员/robot，需官方 Harbor 或前置 auth 代理。
- Funnel :10000 是公网入口，务必强口令；如收紧到 tailnet-only，关闭该 Funnel 端口改 tailnet 直连。

## 7. 验收判据（标注已验证 / 待办）

| # | 判据 | 状态 |
|---|---|---|
| 1 | 容器 healthy，`curl -k https://HOST:10000/v2/` 返回 401 + Docker-Distribution 头 | 待镜像上线 |
| 2 | `docker login HOST:10000` 用 admin/口令成功 | 待镜像上线 |
| 3 | `docker push HOST:10000/demo:v1` 成功、`docker pull` 一致 | 待镜像上线 |
| 4 | check-lan.sh registry case 通过（内网 /v2/ 200/401） | 待镜像上线 |
| 5 | 门禁 make check / check-all 全绿（清单 11 服务 + registry HASHED） | 骨架已过（见日志） |
