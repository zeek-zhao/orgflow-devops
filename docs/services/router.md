# router

路由注册服务。把 `config/routes.yaml` 渲染成 Caddyfile，盯着文件变化热加载进 Caddy。

它不转发任何业务流量——流量走 `caddy`。它的价值只有一个：**让路由只有一个真源**（YAML），
不用手写也不用直接改 Caddyfile。

## 用途与端口

| 项 | 值 |
|---|---|
| 容器名 | `of-router` |
| 固定 IP | `172.31.0.11` |
| 健康端口 | `8090`（`/healthz`，容器内） |
| 镜像 | 自建 `orgflow/router:24.04-v1`，基于 `ubuntu:24.04@sha256:fe8156…` |

## 入口与依赖

- **入口**：不对外。只有 `caddy` 通过 `depends_on` 等它 healthy，健康检查打 `:8090/healthz`
- **依赖谁**：`dnsmasq`（解析 `caddy` 这个名字）、`caddy` 的管理 API（`CADDY_ADMIN_URL`）
- **被谁依赖**：`caddy` 等它 healthy 才启动（否则启动时 Caddyfile 尚未渲染）

## 部署与配置

```bash
make render                          # 一次性渲染（本地也能跑，不需要容器）
docker compose up -d router          # 起容器后进入 watch 模式
```

`make render` 做两件事：渲染 `out/Caddyfile`，再渲染 `out/dex/config.yaml`。

**渲染是原子的**：先写临时文件再替换。校验失败时**不落盘**，上一版 Caddyfile 继续生效——
所以渲染出错不会把 Caddy 弄挂，只是新路由不生效。

| 环境变量 | 作用 |
|---|---|
| `ROUTES_FILE` | 读哪个 YAML，默认 `/app/config/routes.yaml` |
| `GATEWAY_DOMAIN` | 覆盖 YAML 里的 `gateway_domain` |
| `CADDY_ADMIN_URL` | Caddy 管理 API，默认 `http://caddy:2019` |

挂载：`./config:/app/config:ro`（读 YAML）、`./out:/app/out`（写产物）。

## 关键环境变量

见上表。三个都有默认值，通常不需要在 `.env` 里配。

## 排查步骤

**1. 渲染结果对不对（不用起容器）**

```bash
make render
grep -c '^https://' out/Caddyfile          # 站点数，应等于 routes.yaml 里路由条数
grep -c 'forward_auth' out/Caddyfile       # 需要登录的站点数
```

**2. 容器活着吗**

```bash
docker inspect -f '{{.State.Health.Status}}' of-router
docker compose exec -T router python3 -c "import urllib.request;print(urllib.request.urlopen('http://localhost:8090/healthz').read().decode())"
```

`/healthz` 返回 `{"ok": true, "routes": 6}`。`ok` 为 `false` 时 HTTP 状态码是 `503`——
说明它还没成功渲染过任何一版（不是「渲染出错」，出错时旧版还在，`ok` 仍是 `true`）。

**3. 渲染失败时报什么**

```bash
docker compose logs --tail=50 router
```

常见报错与含义：

| 报错 | 原因 |
|---|---|
| `duplicate subdomain` | 两条路由用了同一个子域 |
| `缺少 name: auth 的路由` | 删掉了 `name: auth` 那条——受保护站点的登录跳转没地方去 |
| `missing upstream` / `invalid subdomain` | 字段缺了或含非法字符 |

渲染失败时日志里一定有 `previous Caddyfile preserved`，说明旧配置还在生效。

**4. 新路由生效了吗**

```bash
docker compose exec -T caddy wget -qS -O /dev/null http://localhost:2019/config/ 2>&1 | head -2
docker compose exec -T caddy sh -c 'grep -c "https://" /etc/caddy/Caddyfile'
```

第二条数字应该和 `out/Caddyfile` 里的站点数一致。不一致说明热加载没成功——看 `router` 日志里
`POST /load` 的响应体。

**5. 热加载为什么没触发**

```bash
docker compose exec -T router ls -l --time-style=full-iso /app/out/Caddyfile
```

`router` 靠 mtime 判断变化。如果 mtime 没变（比如内容相同被跳过写入），就不会 reload——
这是正常的，内容没变本来也不用 reload。

## 常用命令

```bash
# 渲染（本地，无需容器）
make render

# 单测（19 项，纯逻辑，不需要 docker）
python3 services/router/test_render.py

# 手动触发一次 reload
docker compose exec -T router sh /app/reload.sh

# 看渲染产物
cat out/Caddyfile

# 校验一份改坏的 routes.yaml 会不会被拒
python3 services/router/render.py --routes /tmp/bad.yaml --out /tmp/x
```
