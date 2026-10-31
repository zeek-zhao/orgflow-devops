# oauth2-proxy

会话守卫。Caddy 在受保护站点前面调它一次（`forward_auth`），由它决定放行还是把人送去登录。

## 用途与端口

| 项 | 值 |
|---|---|
| 容器名 | `of-oauth2` |
| 固定 IP | `172.31.0.25` |
| 端口 | `4180`（容器内，不发布到宿主） |
| 镜像 | `quay.io/oauth2-proxy/oauth2-proxy:v7.6.0@sha256:dcb6ff8d…` |

镜像基于 **distroless**——里面没有 shell、没有 `curl`、没有 `wget`。所以：

- 健康检查只能做进程级探测：`/bin/oauth2-proxy --version`
- 排查时**不能** `docker compose exec -it of-oauth2 sh`，会直接失败

要探它的 HTTP 端点，从别的容器发：

```bash
docker compose exec -T router wget -qO- http://oauth2-proxy:4180/ping
```

## 入口与依赖

- **入口**：`https://auth.org-devops.com`。这个子域由 `routes.yaml` 里 `name: auth` 那条路由决定，
  **没有独立的环境变量**——受保护站点的登录跳转就打到这个站点的 `/oauth2/start`
- **依赖谁**：`dex`（IdP）、`dnsmasq`
- **被谁依赖**：所有 `auth: true` 的站点（目前是 jenkins）

**关键设计：认证域名与业务域名分离。** 浏览器侧走 `https://auth.<domain>`，
服务端到服务端（redeem / jwks）走容器网络 `http://dex:5556`。这样换 token 不绕公网，
也不会因为局域网访问不到公网域名而登录失败。

## 部署与配置

启动参数全在 `docker-compose.yml` 的 `command:` 里，没有配置文件。

```bash
docker compose up -d oauth2-proxy
```

| 参数 | 值 | 为什么 |
|---|---|---|
| `--provider=oidc` | 用 OIDC | 7.x 已无 LDAP provider |
| `--skip-oidc-discovery=true` | 跳过发现 | 发现文档走公网域名，容器内解析不到；改成显式给端点 |
| `--login-url` | `https://dex.<domain>/dex/auth` | 浏览器要能打开，必须公网域名 |
| `--redeem-url` | `http://dex:5556/dex/token` | 服务端到服务端，走容器网络 |
| `--oidc-jwks-url` | `http://dex:5556/dex/keys` | 同上 |
| `--insecure-oidc-skip-issuer-verification=true` | 跳过 issuer 校验 | issuer 是公网域名，实际请求是容器网络，host 必然对不上 |
| `--upstream=static://202` | 不反代任何东西 | 它只做鉴权判断，返回 202 表示放行 |
| `--cookie-secure=true` | cookie 只走 HTTPS | 网关已是 TLS |
| `--cookie-domain=.<domain>` | cookie 跨子域共享 | 登录在 auth 站，业务在别的子域 |

## 关键环境变量

| 变量 | 作用 | 注意 |
|---|---|---|
| `OAUTH2_CLIENT_ID` | OIDC client id | 默认 `jenkins`，必须与 Dex 的 staticClient 一致 |
| `OAUTH2_CLIENT_SECRET` | client secret | 必须与 Dex 侧一致，不一致表现为登录后跳回登录页 |
| `OAUTH2_COOKIE_SECRET` | cookie 加密密钥 | **必须正好 32 字节**。20 字符的旧默认值会让它启动即报错 |

## 排查步骤

**1. 进程活着吗**

```bash
docker inspect -f '{{.State.Health.Status}}' of-oauth2
```

因为健康检查是 `--version`，`healthy` 只证明**进程能跑**，不证明配置对。所以必须往下走。

**2. 配置加载对了吗**

```bash
docker compose logs --tail=50 oauth2-proxy | grep -iE 'error|fatal|cookie'
```

`cookie secret must be 16, 24, or 32 bytes` → `OAUTH2_COOKIE_SECRET` 长度不对。

**3. `/ping` 通吗**

```bash
docker compose exec -T router wget -qS -O /dev/null http://oauth2-proxy:4180/ping 2>&1 | head -2
```

期望 `HTTP/1.1 200 OK`。这条不通说明进程虽然在，但 HTTP 服务没起来——回去看日志。

**4. 走网关的 `/ping`**

```bash
curl -sS -k -o /dev/null -w '%{http_code}\n' --resolve auth.org-devops.com:443:127.0.0.1 https://auth.org-devops.com:443/ping
```

期望 `200`。这条失败而第 3 步成功 → 网关层问题，查 `routes.yaml` 里有没有 `name: auth` 这条。

**5. 未登录跳转对不对**

```bash
curl -sS -k -o /dev/null -w '%{http_code} %{redirect_url}\n' --resolve jenkins.org-devops.com:443:127.0.0.1 https://jenkins.org-devops.com:443/
```

期望 `302`，跳转目标以 `https://auth.org-devops.com/oauth2/start?rd=` 开头。
如果跳到别的域名，说明 `routes.yaml` 里 `name: auth` 那条的子域和实际站点不一致——
这两处曾经是分开配的（`AUTH_SUBDOMAIN` 环境变量），现在已合并成单一真源。

**6. 登录后跳回登录页（最常见）**

按顺序排除：

```bash
# a) 两端 client secret 是否一致
docker compose exec -T dex grep -A3 staticClients /etc/dex/config.yaml
docker compose config | grep -A2 'client-secret'

# b) cookie 域名是否覆盖当前访问的域名
docker compose config | grep cookie-domain

# c) redeem 通不通（容器网络内）
docker compose exec -T router wget -qS -O /dev/null --post-data '' http://dex:5556/dex/token 2>&1 | head -2
```

`(c)` 返回 `400` 是正常的（缺参数），返回 `connection refused` 才是问题。

## 常用命令

```bash
# 重启
docker compose restart oauth2-proxy

# 从别的容器探 /ping（它自己没有 shell）
docker compose exec -T router wget -qO- http://oauth2-proxy:4180/ping

# 看实际生效的参数
docker compose config | sed -n '/oauth2-proxy:/,/^  [a-z]/p' | head -40

# 清掉登录态（本地调试时把 cookie 弄脏了）
# 浏览器里删掉 .org-devops.com 域下的 _oauth2_proxy cookie
```

## 已知边界

- **distroless**：不能 exec 进去，排查只能靠日志和从别的容器发请求
- `--insecure-oidc-skip-issuer-verification=true` 是必要的妥协，原因见上表
- 没有配 `--session-store`，会话在内存里，重启后所有人重新登录
