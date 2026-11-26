# registry（M2.2 轻量镜像仓库）

Docker Distribution `registry:2` + htpasswd 基础鉴权。相比官方 Harbor 全栈（6 容器 + PG/Redis），
本方案内存占用小、冷启动快，适配本沙箱 8GiB 内存/8GiB swap 的资源闸门（见 `docs/services/gerrit.md` §8 选型建议）。

## 边界（M2.2 范围）

- 提供：镜像 push/pull、`/v2/` API、htpasswd 单用户基础鉴权、数据卷持久化。
- 不提供：Web UI、项目/成员管理、robot 账号、复制策略、扫描（如需这些能力再评估官方 Harbor 全栈）。

## 端口与入口

- 容器监听 5000 → 宿主回环 `127.0.0.1:18086`（`PUB_HTTP_HARBOR`）→ Tailscale Funnel `:10000`。
- 不经 Caddy：Registry `/v2/` 协议对路径前缀/重定向敏感，独立端口直连最稳。
- 公网地址：`https://orgflow-sandbox.tail0b7621.ts.net:10000`。

## 凭据

- `REGISTRY_USER` / `REGISTRY_PASSWORD` 经 env 注入（默认 admin/change-me，生产须改 `.env`）。
- entrypoint 用 `htpasswd -B`（bcrypt）渲染到卷 `/auth/htpasswd`（600），幂等、不入库。
- push/pull 前先 `docker login orgflow-sandbox.tail0b7621.ts.net:10000`。

## 镜像与供应链

- 薄封装：`FROM registry:2@<digest>`（上游 digest 钉在 `config/images.env` 的 `UPSTREAM_REGISTRY`），
  加装 `apache2-utils` 提供 htpasswd。CI 在海外 runner 构建推 GHCR `m2-registry:ctx-<12>`，
  国内经 `ghcr.nju.edu.cn` 代理拉取。

## 已知约束

- 单用户 htpasswd：项目级隔离/多成员需官方 Harbor 或前置 auth 代理，M2.2 不做。
- Funnel 10000 是公网入口，凭据务必强口令；如收紧到 tailnet-only，改为 Funnel 关闭 + tailnet 直连。
