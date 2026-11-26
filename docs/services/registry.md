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

- 薄封装：`FROM registry:2@${BASE_DIGEST}` + `apache2-utils`（提供 htpasswd）。
- 上游 digest：CI `docker pull registry:2` 取 RepoDigests 产出，回填 `UPSTREAM_REGISTRY`（config/images.env）、
  `tests/images.lock`、`docs/运维/镜像与供应链.md`；M2.2 P2-2 起 Dockerfile 用 `ARG BASE_DIGEST=<真实64位默认值>`，
  仓库可直接 `docker build`（默认即可构建），CI 用 `docker build --build-arg BASE_DIGEST=$UP` 注入当日实拉值，不再 sed 改文件。
- tag：`orgflow/m2-registry:ctx-1cb303e1dbfa`（= `image-hash.sh registry` 前 12 位），由 CI 推 GHCR
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
- **公网 push 大 blob 不稳**：经 Funnel :10000 推 26MB 镜像实测 blob 上传多次重试后超时（Funnel 对大 payload 传输不稳）；`/v2/` 元数据/login 正常。推送构建产物建议在 tailnet 内走 `127.0.0.1:18086` 回环；公网入口适合 pull/只读与小层推送。

### 6.1 客户端接入：TLS / insecure-registries（M2.2 P1-4 入库）

链路：`Funnel TLS :10000 → 127.0.0.1:${PUB_HTTP_HARBOR:-18086}（明文 HTTP）→ 容器 :5000`。

- **公网入口（`HOST:10000`）**：Funnel 边缘已终止 TLS，客户端走标准 HTTPS，无需任何 insecure 配置；这是推荐的 pull/只读入口。
- **本机回环（`127.0.0.1:18086`）**：Docker daemon 对 loopback 地址（`127.0.0.1`/`::1`/`localhost`）**内置信任明文 HTTP**，所以 `docker login/push` 不需要 `insecure-registries`。此前复核文档推测"daemon.json 配了 insecure"并不准确——仓库与宿主 `daemon.json` 均无该项，能登录是 loopback 的内置行为，不依赖某台机器的私有配置。
- **内网非回环地址（`192.168.90.20:5000` / `registry:5000`）**：Docker 默认要求 HTTPS，明文直连会被 TLS 校验拦下。**这是 M2.3 buildkitd/agent 从内网推镜像前必须解决的项**，本轮（M2.2 收口，约束"镜像只由 CI 出、不在宿主装东西"）不改宿主 daemon、不重建 agent 镜像。

**可复现的客户端信任清单（入库，不再只活在机器上）**：

| 客户端场景 | 地址 | 方案 | 注入位置 / 责任人 |
|---|---|---|---|
| 公网 pull/只读 | `HOST:10000` | Funnel 边缘 TLS，无需配置 | 无（透明） |
| 本机回环 push | `127.0.0.1:18086` | Docker loopback 内置明文信任 | 无（透明） |
| 内网 push（M2.3） | `192.168.90.20:5000` / `registry:5000` | 二选一（见下） | M2.3 实施者 |

内网 push 两条路线（M2.3 选定其一后落地）：

1. **推荐：内网 CA 证书 + HTTPS**。给 registry 签 SAN 含 `registry` / `192.168.90.20` / `127.0.0.1` 的服务证书，registry 挂 cert 走 HTTPS 5000；客户端信任 CA 放进各 agent/builder 镜像 `/etc/docker/certs.d/registry:5000/ca.crt`。CA 由 `services/certs-init/gen-ca.sh` 派生（需扩展 SAN），镜像由 CI 重建。
2. **明文 + insecure-registries**：在所有需推送的 Docker daemon `daemon.json` 增加 `{"insecure-registries": ["192.168.90.20:5000", "registry:5000"]}` 并 `systemctl restart docker`。注入责任：M2.3 的基础设施即代码（当前宿主 `daemon.json` 仅含 storage-driver/data-root，无此项，不得假设已配）。

## 7. 验收判据（2026-11-26 实测）

| # | 判据 | 状态 |
|---|---|---|
| 1 | 容器 healthy，`curl -k https://HOST:10000/v2/` 返回 401（本地 18086 亦 401，鉴权生效） | ✅ 已验证 |
| 2 | `docker login HOST:10000` / `127.0.0.1:18086` 用 admin/口令成功 | ✅ 已验证 |
| 3 | `docker push 127.0.0.1:18086/demo:test001` 成功、`docker pull` 一致（digest `fd56a3be…d04be`）、`_catalog` 返回 `["demo"]` | ✅ 已验证（走本地回环，公网 push 见 §6） |
| 4 | 匿名 pull 被拒（`no basic auth credentials`）；check-lan.sh registry case（内网 /v2/ 200/401） | ✅ 已验证 |
| 5 | 门禁 make check / check-all 全绿（清单 11 服务 + registry HASHED） | ✅ 已验证 |

## 8. 上线记录（2026-11-26）

- 镜像：CI run 45756551160 构建推 GHCR `m2-registry:ctx-1cb303e1dbfa`（上游 registry:2 digest `sha256:a3d8aaa6…15373`），经 `ghcr.nju.edu.cn` 拉取本地。
- 踩坑：① entrypoint 首次建 htpasswd 缺 `-c` 致容器 Exit 1（已修，加 `-c`）；② `REGISTRY_LOG_LEVEL=warning` 非法（合法 `warn`，已修）；③ healthcheck 用 busybox wget `-S` 抓不到响应头，改用 stderr 的 `401` 判据（已修）。
- 数据卷 registry_data / registry_auth 由 up.sh 幂等预建；容器固定 IP 192.168.90.20，回环 18086→5000。
