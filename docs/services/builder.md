# builder 服务手册（M2.3 rootless BuildKit）

> 状态：骨架已落地，待 CI 构建上线 | 最后核对：2026-11-26 | 对应分支：feat/m2-gerrit-cgit-harbor

## 1. 职责与边界

`moby/buildkit:rootless` 独立构建容器，供 Jenkins agent 经内网卡 `tcp://builder:1234` 提交镜像构建（`BUILDKIT_HOST`）。

- **提供**：OCI 镜像 build + push（走 `buildctl`），内部 registry 的 http/insecure 声明，构建缓存卷持久化。
- **不提供**：宿主 docker.sock（controller 与 agent 都没有）、公网入口、mTLS、UI。
- **为什么独立容器**：controller `numExecutors=0` 不跑构建；agent 是普通用户、无 docker socket，构建统一收敛到 builder，缩小权限面。

## 2. 端口与入口

| 层 | 地址 |
|---|---|
| 容器 | `builder:1234`（`P_BUILDKIT`，gRPC） |
| 宿主 | **不发布**（`compose` 无 `ports`） |
| 客户端 | Jenkins agent 内 `BUILDKIT_HOST=tcp://builder:1234` |

只在 `orgflow-minimal_orgflow` 内网可达。内网明文 gRPC（无 mTLS）是已知取舍：network 不对外、无宿主端口；后续可加 buildkitd TLS，不在 M2.3。

## 3. 镜像与供应链

- 薄封装：`FROM moby/buildkit:v0.16.0-rootless@${BASE_DIGEST}`（amd64 manifest digest 钉死），仅补 `buildkitd.toml`。
- 上游 digest 真值：`UPSTREAM_BUILDER`（config/images.env）、`tests/images.lock`、`docs/运维/镜像与供应链.md`。
- tag：`orgflow/m2-builder:ctx-9e393f1c9787`（= `image-hash.sh builder` 前 12 位），CI（build-images.yml）推 GHCR
  `ghcr.io/zeek-zhao/orgflow-devops/m2-builder:<tag>`，国内经 `ghcr.nju.edu.cn` 代理拉取。
- agent 侧 `buildctl` 从同版本 buildkit 镜像多阶段 COPY，避免版本漂移。

## 4. registry 连接口径（D1 决策）

registry 保持内网明文 HTTP（`192.168.90.20:5000`），**不改 HTTPS**——Funnel 边缘已终止 TLS、回源明文，
改容器为 TLS 会让公网 `:10000` 入口立刻 502。`buildkitd.toml` 声明该仓库 `http = true`，仅限内网 bridge。

残差风险：明文仅存在于内网段，network 不对外、builder 无宿主端口。真正上 TLS 的时机是前置一层
Caddy（`Funnel → Caddy TLS :18086 → registry:5000`），属独立改造，不在 M2.3。

## 5. 健康与验证

- healthcheck：容器内 `buildctl --addr tcp://127.0.0.1:1234 debug workers` 返回非空。
- LAN 探测：`check-lan.sh builder`（`nc -z builder 1234`）。
- agent 侧：`docker exec of-jenkins-agent buildctl --version` 有输出；`BUILDKIT_HOST=tcp://builder:1234 buildctl debug workers` 见 `linux/amd64` worker。

## 6. 资源与回滚

- security_opt：`seccomp=unconfined` / `apparmor=unconfined`（rootless 需要）。
- 缓存卷 `builder_cache`（`orgflow-minimal_builder_cache`），由 up.sh 幂等预建；重建 builder 不清缓存。
- 回滚：`bash up.sh --only builder`（停容器不影响其它服务）；镜像回滚用旧 ctx tag + `up.sh --recreate builder --no-pull`。
