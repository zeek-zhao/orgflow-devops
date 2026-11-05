# caddy

网关。唯一对外发布端口的容器，按域名分流到各服务，并做统一登录的 `forward_auth`。

## 用途与端口

| 项 | 值 |
|---|---|
| 容器名 | `of-caddy` |
| 固定 IP | `172.31.0.10` |
| 对外端口 | 宿主 `${GATEWAY_HTTP_PORT:-80}` → 容器 `80`；宿主 `${GATEWAY_HTTPS_PORT:-443}` → 容器 `443` |
| 管理端口 | `2019`（容器内，不对外） |
| 镜像 | `caddy:2@sha256:36c24ad9…` |

Caddyfile **不是手写的**，由 `router` 从 `config/routes.yaml` 渲染到 `out/Caddyfile` 再挂进来。
手改 `out/Caddyfile` 会在下一次 `make render` 时被覆盖。

## 入口与依赖

- **入口**：`https://<subdomain>.<GATEWAY_DOMAIN>`，默认域名 `org-devops.com`
- **依赖谁**：`router`（要它渲染好 Caddyfile 并 healthy）、`dnsmasq`（解析上游服务名）
- **被谁依赖**：所有业务站点，以及局域网访问（局域网机器直连宿主 443）

TLS 用 Caddy **内部 CA**（`local_certs`），不向公网申请证书。所以客户端必须导入 `out/ca/root.crt`，
否则浏览器报证书错误——这不是故障。

## 部署与配置

```bash
make render          # routes.yaml → out/Caddyfile（同时渲染 dex 配置）
docker compose up -d router caddy
```

| 文件 | 作用 |
|---|---|
| `config/routes.yaml` | **唯一真源**：站点、子域、上游、是否要登录 |
| `out/Caddyfile` | 渲染产物，只读挂载进容器 |
| `out/ca/root.crt` | 内部 CA 根证书，分发给客户端 |
| `caddy_data` 卷 | Caddy 的内部 CA 与已签证书 |

改路由后 `router` 会热加载（`POST /load`），不必重启 Caddy。渲染失败时上一版 Caddyfile 继续生效。

## 关键环境变量

Caddy 容器本身没有业务环境变量。相关的是宿主侧的：

| 变量 | 作用 |
|---|---|
| `GATEWAY_DOMAIN` | 域名后缀，渲染时写进 Caddyfile |
| `GATEWAY_HTTP_PORT` | 宿主 80 被占用时改这里 |
| `GATEWAY_HTTPS_PORT` | 宿主 443 被占用时改这里 |
| `CADDY_ADMIN_URL` | `router` 调 Caddy 管理 API 的地址，默认 `http://caddy:2019` |

## 排查步骤

分四层，从外往里。每层通过再进下一层——**不要在底层反复试，先确认外层通了**。

**第 1 层：宿主端口在听吗**

```bash
ss -ltnp | grep -E ':(80|443)\b'
```

期望有 `docker-proxy` 在听。没有的话，要么容器没起，要么端口被别的进程占了（`nginx`、宿主自带的 web 服务）。

```bash
docker compose ps caddy
```

**第 2 层：TLS 握手过得了吗**

```bash
curl -sS -o /dev/null -w '%{http_code}\n' --cacert out/ca/root.crt https://jenkins.org-devops.com/
```

期望 `302`（受保护站点，未登录跳转）。`SSL certificate problem` 说明客户端没信任内部 CA，
不是服务坏了。加 `-k` 能过而这条不能过，就是 CA 信任问题。

**第 3 层：Caddy 认得这个域名吗**

```bash
curl -sS -k -o /dev/null -w '%{http_code}\n' --resolve jenkins.org-devops.com:443:127.0.0.1 https://jenkins.org-devops.com:443/
```

注意 `--resolve` 的端口必须和 URL 里的端口一致（这里都是 443）。端口不一致时 curl 会去查 DNS，
报出来的却是 `Could not resolve host`——看着像 DNS 问题，实际是参数写错。

`404` 说明 Caddy 起来了但没有这个域名的站点 → 查 `routes.yaml` 有没有这条、`make render` 跑过没有。

**第 4 层：上游通吗**

```bash
docker compose exec -T caddy wget -qS -O /dev/null http://jenkins:8080/login 2>&1 | head -3
docker compose logs --tail=30 caddy | grep -E 'dial|refused|no such host'
```

`dial tcp: lookup jenkins: no such host` 是 DNS 问题（查 dnsmasq）；
`connection refused` 是上游服务没起（查那个服务）。

**看 Caddy 自己怎么说**

```bash
curl -sS http://172.31.0.10:2019/config/ | head -c 500   # 当前生效的配置
docker compose logs --tail=100 caddy                       # 访问日志与错误
```

## 常用命令

```bash
# 重新渲染并热加载
make render

# 只看渲染结果，不起容器
python3 services/router/render.py --routes config/routes.yaml --out /tmp/caddyfile && cat /tmp/caddyfile

# 导出并安装内部 CA（客户端要信任它才能免警告访问）
make ca

# 站点清单（渲染后有多少个站点）
grep -c '^https://' out/Caddyfile

# 校验当前配置语法
docker compose exec -T caddy caddy validate --config /etc/caddy/Caddyfile
```

## 给别的机器装根证书（#62）

根证书不入库（会过期），运行时从网关拉：`ca` 站点（上游 router:8090）服务
`out/ca/` 下的 `root.crt` 与 `ca-install.sh`。

网关机上先导出（幂等，会同时把安装脚本放进 out/ca）：

```bash
bash scripts/ca-install.sh --export
```

局域网 Linux 机器一条命令（脚本 = 拉证书 + 装信任库 + 校验三步）：

```bash
curl -kfsSL https://ca.org-devops.com/ca-install.sh -o /tmp/ca-install.sh
sudo bash /tmp/ca-install.sh https://ca.org-devops.com
```

> 首次下载用 `-k` 是自举（此刻机器还不信任内部 CA），不是掩盖证书问题：
> 脚本装完会用**不带 -k** 的请求复验，失败即非零退出。网关地址错/不可达/
> 拉到的不是本环境 CA 也都非零退出（bats 反证覆盖）。

Windows 用 [`tools/win-acceptance/Import-OrgflowRootCa.ps1`](../../tools/win-acceptance/Import-OrgflowRootCa.ps1)。
证书变更（`down -v` 会让 Caddy 重新生成 CA）后所有客户端重装。
