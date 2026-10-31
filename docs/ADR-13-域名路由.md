# ADR-13：网关改域名路由（固定 IP + 内部 CA）

- 状态：已采纳（M0）
- 影响面：`config/routes.yaml`、`services/router/render.py`、`docker-compose.yml`、
  `.env`、`scripts/*`、`tests/bats/*`

## 背景

M0 最初把 Caddy 当「路径前缀反代」用：`http://localhost:8080/jenkins`、
`/nexus/`、`/ldapadmin/`、`/dex/`、`/auth/`。这套模型有三个绕不过去的问题：

1. **上游应用不认前缀**。Jenkins 需要 `--prefix=/jenkins`、Nexus 需要
   `X-Forwarded-Prefix`、phpLDAPadmin 的相对链接会丢前缀、Dex 的 issuer 必须是
   绝对 URL。每加一个服务都要重新解一遍「前缀适配」，且适配代码散落在各服务配置里。
2. **OAuth2 回调路径耦合**。`redirect_uri` 与 `issuer` 都带路径，改一次路由前缀就要
   同步改 Dex 配置、oauth2-proxy 参数、Cookie 作用域，容易漏。
3. **排查只能靠端口**。所有入口都是 `localhost:8080`，看不出请求最终落到哪个容器；
   容器 IP 是随机分配的，`docker ps` 与架构图对不上。

## 决策

网关改成**域名路由 + 固定 IP + 内部 CA**：

- 每个服务一个独立站点：`https://<subdomain>.<GATEWAY_DOMAIN>`。
  默认域名 `org-devops.com`，由 `.env` 的 `GATEWAY_DOMAIN` 决定。
- 站点集合由 `config/routes.yaml` 声明（`name` / `subdomain` / `upstream` / `auth`），
  `services/router/render.py` 渲染成 Caddyfile 并热加载。**不再支持路径路由**。
- `docker-compose.yml` 给每个服务写死 `ipv4_address`（`172.31.0.0/24`），
  排查时按 IP 就能定位容器。
- 新增 `dnsmasq` 容器（`172.31.0.2`）做容器内 DNS：`*.org-devops.com` 解析到
  Caddy 的 `172.31.0.10`，其余查询转发 Docker 内嵌 DNS（`127.0.0.11`），
  所以 `ldap` / `dex` 这类服务名照旧可用。
- Caddy 用 `local_certs`（内部 CA）自签，不向公网申请证书；根证书由
  `scripts/ca-install.sh` 导出并装进系统信任库。

## 固定 IP 表

| IP | 服务 | 作用 |
|---|---|---|
| `172.31.0.2` | dnsmasq | 容器内 DNS |
| `172.31.0.10` | caddy | 网关（:80 跳转 / :443 站点） |
| `172.31.0.11` | router | 渲染 + 热加载 |
| `172.31.0.20` | jenkins | CI 主控（受保护） |
| `172.31.0.21` | nexus | 制品库 |
| `172.31.0.22` | ldap | 目录服务 |
| `172.31.0.23` | ldapadmin | 目录管理 UI |
| `172.31.0.24` | dex | OIDC |
| `172.31.0.25` | oauth2-proxy | 认证网关 |

子网刻意避开 devops 仓库环境用的 `172.30.0.0/24`，两个栈可以同时在本机跑。

## 站点表

| 站点 | 上游 | 认证 |
|---|---|---|
| `https://jenkins.<domain>/` | `jenkins:8080` | 是（forward_auth） |
| `https://nexus.<domain>/` | `nexus:8081` | 否 |
| `https://ldapadmin.<domain>/` | `ldapadmin:80` | 否 |
| `https://dex.<domain>/dex/*` | `dex:5556` | 否 |
| `https://auth.<domain>/oauth2/*`、`/ping` | `oauth2-proxy:4180` | 否 |

## 名字解析

两段，各管一段，互不依赖：

- **容器内**：所有服务 `dns: 172.31.0.2`，由 dnsmasq 供货。所以
  `oauth2-proxy` 能用 `https://dex.<domain>/dex` 当 issuer，`caddy` 能用域名
  找到上游。
- **宿主机 / 局域网机器**：用 hosts 片段（`make hosts`）。不改路由器 DNS 是
  有意的——实验室网络里塞一条泛域名解析会影响其他设备，而 hosts 只影响目标机。

**dnsmasq 不能绑 `0.0.0.0:53`**：Docker 在每个容器的 `127.0.0.11:53` 上跑了内嵌
DNS，`0.0.0.0:53` 会与它端口冲突（`EADDRINUSE`），容器直接起不来。所以配置里
用 `listen-address=172.31.0.2` + `bind-interfaces` 只绑自己的地址；客户端通过
`dns: 172.31.0.2` 指过来，不受影响。验证解析要 `@172.31.0.2`，`@127.0.0.1`
在 dnsmasq 容器里问的是 Docker 内嵌 DNS，必然 NXDOMAIN。

局域网访问时域名要指向**部署机的局域网 IP**，不是 `127.0.0.1`：

```bash
bash scripts/gen-hosts.sh 192.168.0.50        # 打印片段
sudo bash scripts/gen-hosts.sh 192.168.0.50 --write
```

## 认证跳转

跨域名后跳转必须是绝对地址，否则浏览器会去
`https://jenkins.<domain>/oauth2/start`（错误的主机）。渲染器生成的规则是：

```
forward_auth oauth2-proxy:4180 {
    uri /oauth2/auth
    copy_headers X-Auth-Request-User X-Auth-Request-Email
    @unauth status 401
    handle_response @unauth {
        redir * https://auth.<domain>/oauth2/start?rd={scheme}://{host}{uri} 302
    }
}
```

`rd` 带完整原始 URL，登录后回到用户本来要去的页面。oauth2-proxy 侧对应：

- `--redirect-url=https://auth.<domain>/oauth2/callback`（浏览器侧，绝对地址）
- `--redeem-url=http://dex:5556/dex/token`、`--oidc-jwks-url=http://dex:5556/dex/keys`
  （服务端到服务端，走容器网络，不绕公网、不受自签证书影响）
- `--cookie-domain=.<domain>`、`--cookie-secure=true`

## 后果

**收益**

- 加服务只改 `routes.yaml` 一行，不用再解前缀适配。
- 每个站点的 `Host` 就是服务身份，`curl --resolve` 可以直接压到指定服务。
- 容器 IP 固定，`docker exec` / 日志 / 架构图能对上号。

**代价**

- 必须维护 hosts 片段（宿主机 + 每台要访问的机器）。
- 必须信任内部 CA，否则浏览器报 `NET::ERR_CERT_AUTHORITY_INVALID`。
  `make ca` 会导出并安装；Firefox 有独立信任库，需要单独导入。
- 80/443 是特权端口，非 root 部署要改 `GATEWAY_HTTP_PORT` / `GATEWAY_HTTPS_PORT`。

**被否决的替代方案**

| 方案 | 否决原因 |
|---|---|
| 继续用路径路由 | 上游适配成本无上限，见「背景」 |
| 用 `*.localhost` | 只在本机成立，局域网访问无解 |
| 自建 wildcard 证书 | 需要公网域名 + DNS-01，M0 不引入外部依赖 |
| 用 mkcert 做 CA | 多一层工具依赖；Caddy 自带内部 CA 已经够用 |
| 改路由器 DNS 做泛解析 | 影响实验室其他设备，不可接受 |

## 排查

按顺序三段，能定位绝大多数问题：

```bash
# 1) 域名解析（容器内）
docker compose exec caddy getent hosts nexus.org-devops.com     # 期望 172.31.0.10
docker compose exec dnsmasq dig +short jenkins.org-devops.com @172.31.0.2

# 2) 容器是否在预期 IP 上
docker compose ps -q nexus | xargs docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}'

# 3) 站点匹配与证书（绕过 hosts，直接把域名钉到网关）
curl -sk --resolve nexus.org-devops.com:443:127.0.0.1 https://nexus.org-devops.com/ -o /dev/null -w '%{http_code}\n'
echo | openssl s_client -connect 127.0.0.1:443 -servername nexus.org-devops.com 2>/dev/null | openssl x509 -noout -subject -issuer
```

| 现象 | 大概率原因 |
|---|---|
| `getent` 解析不到域名 | dnsmasq 没起 / 服务没配 `dns: 172.31.0.2` / `GATEWAY_DOMAIN` 不一致 |
| 浏览器证书告警 | 没装根证书（`make ca`），或 FireFox 独立信任库未导入 |
| 站点 404 | `routes.yaml` 没这个 subdomain，或渲染后没热加载（看 router 日志） |
| Jenkins 一直 302 循环 | `redirect_uri` / `issuer` 与实际访问域名不一致，检查 `out/dex/config.yaml` |
| `curl` 通、浏览器不通 | hosts 指到了 `127.0.0.1` 而不是部署机局域网 IP |
