# dex

OIDC 身份提供方。把 LDAP 里的用户包装成标准 OIDC，让 `oauth2-proxy` 能消费。

引入它是因为 **`oauth2-proxy` 7.x 已经删掉了 LDAP provider**——`--ldap-*` 参数一个都不剩，
传进去直接 `unknown flag`。所以链路只能是 `oauth2-proxy → Dex → LDAP`，不能直连。

## 用途与端口

| 项 | 值 |
|---|---|
| 容器名 | `of-dex` |
| 固定 IP | `172.31.0.24` |
| 端口 | `5556`（容器内，不发布到宿主） |
| 镜像 | `ghcr.io/dexidp/dex:v2.41.1@sha256:bc7cfce7…` |
| 配置 | `./out/dex/config.yaml` → `/etc/dex/config.yaml:ro`（**单文件挂载**） |

**必须单文件挂载，不能挂整个目录。** dex 以 uid `1001` 运行，它的 entrypoint 会先
`chdir /etc/dex` 再 fork `gomplate` 渲染配置。整目录挂载会把镜像里那个 `1001:1001 / 0755`
的 `/etc/dex` 换成宿主目录，权限一变就 chdir 失败——而报出来的错误是
`fork/exec /usr/local/bin/gomplate: permission denied`，看着像 gomplate 的问题，实际是目录权限。

## 入口与依赖

- **入口**：`https://dex.org-devops.com/dex/`。**所有端点都挂在 `/dex` 下**——
  ADR-13 的域名路由不剥路径前缀，所以发现文档是 `/dex/.well-known/openid-configuration`，
  不是 `/.well-known/openid-configuration`
- **依赖谁**：`ldap`（用户来源）、`dnsmasq`
- **被谁依赖**：`oauth2-proxy`（要它的 issuer、token、jwks 端点）

| 端点 | 用途 |
|---|---|
| `/dex/.well-known/openid-configuration` | 发现文档 |
| `/dex/auth` | 登录页（浏览器来这） |
| `/dex/token` | 换 token（**服务端到服务端**，走 `http://dex:5556`） |
| `/dex/keys` | JWKS 签名公钥 |
| `/dex/healthz` | 健康检查 |

## 部署与配置

配置是**渲染**出来的，不是手写：

```bash
make render                       # 同时渲染 out/Caddyfile 和 out/dex/config.yaml
docker compose up -d dex
```

模板在 `services/auth/dex/config.yaml.tmpl`，渲染脚本 `scripts/render-dex.sh`。
渲染后脚本会 `chmod 0644`——调用方的 umask 可能是 `077`，那样 uid 1001 读不到配置，
症状同样是那句误导人的 gomplate 报错。

| 项 | 值 |
|---|---|
| storage | `memory`（**重启丢 refresh token**） |
| connector | `ldap`，指向 `ldap:389`，base DN `dc=devops,dc=com` |
| static client | `jenkins`，secret 来自 `OAUTH2_CLIENT_SECRET` |

## 关键环境变量

| 变量 | 作用 | 来源 |
|---|---|---|
| `LDAP_ADMIN_PASSWORD` | connector 绑定 LDAP 用 | `.env` |
| `OAUTH2_CLIENT_SECRET` | static client 的 secret，必须与 oauth2-proxy 一致 | `.env` |

模板里用的是 Dex 原生的 **`secretEnv`** 字段，不是 `${...}` 展开——Dex **不展开** `secret` 里的
`${...}`，写成那样会得到一个字面量 `${OAUTH2_CLIENT_SECRET}`，登录时报 secret 不匹配。

## 排查步骤

**1. 容器健康吗（这里最容易误判）**

```bash
docker inspect -f '{{.State.Health.Status}}' of-dex
docker compose ps dex
```

如果状态是 `Restarting` 且日志里是 `fork/exec /usr/local/bin/gomplate: permission denied`，
**不要去查 gomplate**，查挂载和权限：

```bash
docker compose logs --tail=20 dex
ls -l out/dex/config.yaml
docker compose exec -T dex ls -ln /etc/dex/
```

`ls` 那两条应该看到 `config.yaml` 是 `0644`，且 `/etc/dex` 属于 `1001:1001`。

**2. 发现文档通吗**

```bash
docker compose exec -T dex wget -qO- http://localhost:5556/dex/.well-known/openid-configuration | head -c 200
```

注意路径带 `/dex`。返回 404 说明路径写错——这是域名路由不剥前缀的直接后果。

**3. 走网关通吗**

```bash
curl -sS -k -o /dev/null -w '%{http_code}\n' --resolve dex.org-devops.com:443:127.0.0.1 https://dex.org-devops.com:443/dex/healthz
curl -sS -k --resolve dex.org-devops.com:443:127.0.0.1 https://dex.org-devops.com:443/dex/.well-known/openid-configuration | python3 -m json.tool | head -8
```

**4. 签名公钥在吗**

```bash
curl -sS -k --resolve dex.org-devops.com:443:127.0.0.1 https://dex.org-devops.com:443/dex/keys | python3 -m json.tool | head -6
```

返回 `{"keys":[...]}`。空数组说明配置没加载成功。

**5. 能查 LDAP 吗（登录失败时查这个）**

```bash
docker compose exec -T dex ldapsearch -x -H ldap://ldap:389 -b dc=devops,dc=com "(uid=admin.zeek)" uid
```

返回空说明这个用户不在目录里，Dex 会报「用户不存在」。

**6. 登录后一直跳回登录页**

多半是 client secret 两端不一致：

```bash
docker compose exec -T dex grep -A3 'staticClients' /etc/dex/config.yaml
docker compose exec -T oauth2-proxy /bin/oauth2-proxy --help 2>/dev/null | grep -i client-secret
```

两边必须一致。另外检查 issuer 是否为 `https://dex.<domain>/dex`（带 `/dex`）。

## 常用命令

```bash
# 重新渲染配置并重启
make render && docker compose restart dex

# 健康端点
docker compose exec -T dex wget -qO- http://localhost:5556/dex/healthz

# 日志（登录问题主要看这里）
docker compose logs --tail=80 dex | grep -iE 'error|failed|login'

# 确认挂载的是单文件而不是目录
docker inspect -f '{{range .Mounts}}{{.Source}} -> {{.Destination}}{{"\n"}}{{end}}' of-dex
```

## 已知边界

- **`storage: memory`**：重启后 refresh token 全丢，已登录用户要重新登录。M1 换持久化存储
- 配置里 `--insecure-oidc-skip-issuer-verification=true`（在 oauth2-proxy 侧）：因为 issuer 走公网域名、
  实际请求走容器网络，两边 host 对不上。这是刻意的，不是安全疏漏——链路在内网
