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

## 注册 API（#61）

routes.yaml 仍是唯一真源，API 只是它的写入口：`POST` 写文件 → 渲染 → Caddy 热加载，
全程不重启容器。文件 watch 依旧可用（手改文件是合法用法）。

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/routes` | 当前路由列表（合法 JSON，含 `gateway_domain`） |
| POST | `/routes` | 注册一条：`{"name":"demo","host":"demo.<domain>","upstream":"caddy:80"}`（`host` 给 FQDN 自动剥后缀，也可直接给 `subdomain`；`auth` 可选布尔） |
| DELETE | `/routes/<name>` | 删除一条；`auth` 路由拒绝删除 |
| GET | `/healthz` | 健康检查（原有） |
| GET | `/root.crt`、`/ca-install.sh` | CA 分发（#62，见 [caddy.md](caddy.md)） |

**校验**（非法一律 400 且 routes.yaml 一个字节不动——bats 有 sha256 反证）：
name/subdomain 只允许小写字母数字连字符；subdomain 不得重复、不得是网关域名本身；
upstream 必填。校验在**写之前**做，写前还会对改完的文本完整走一遍 parse+render。

**鉴权口径（#61 前置项的结论）：不加鉴权。** router 只在容器网络内、不对外发布端口，
与 Caddy admin（`caddy:2019`）同口径；能打到 8090 的只有同一 docker 网络里的容器。
威胁模型变了的话（比如 router 端口对外发布），必须先补鉴权再用。

**注意**：config 挂载因此从 `:ro` 改为读写（compose 里有注释）。

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

## 使用指南

```bash
make render                                   # 本地渲染，无需容器
python3 services/router/test_render.py        # 19 项纯逻辑单测
cat out/Caddyfile                              # 看渲染产物
docker compose exec -T router sh /app/reload.sh    # 手动触发一次 reload
```

改 `config/routes.yaml` 后由 `router` 容器 `--watch` 自动热加载，日常不需要手动 reload。

## 注意事项

- **宿主跑 `make render` 不会热加载**：真机制是 `router` 容器轮询 mtime + `POST /load` 到 Caddy admin；Caddy admin 只在容器网络 `caddy:2019`，宿主够不到。
- `config/routes.yaml` 是**路由唯一真源**，没有第二处配路由；`out/Caddyfile` 是渲染产物，别手改。
- 渲染是原子的：校验失败**不落盘**，上一版继续生效，日志里会有 `previous Caddyfile preserved`；`/healthz` 的 `ok:false` 是「从没成功渲染过一版」，不是「渲染出错」。
- `USE_GHCR=1` 时对有 `build:` 的服务加 `--build` 会报 `refusing to create a tag with a digest reference`。
- 删除 `name: auth` 路由会让受保护站点的登录跳转没地方去，渲染会直接报 `缺少 name: auth 的路由`。

## 设置

| 真源 / 产物 | 路径 |
|---|---|
| 路由唯一真源 | `config/routes.yaml` |
| 渲染器与模板 | `services/router/render.py` + `services/router/` 模板 |
| 容器挂载 | `docker-compose.yml` 的 `router` 段：`./config:/app/config:ro`、`./out:/app/out` |
| 渲染产物 | `out/Caddyfile`、`out/dex/config.yaml` |
| 变量 | `.env` 的 `ROUTES_FILE` / `GATEWAY_DOMAIN` / `CADDY_ADMIN_URL` |

## 备份

router **无状态、无数据卷**：`config/routes.yaml` 在 Git，`out/` 是可重建的渲染产物（不备），
容器随时可起，不在 `make backup` 范围内。见
[备份与恢复](../备份与恢复.md)「范围与前提」。
