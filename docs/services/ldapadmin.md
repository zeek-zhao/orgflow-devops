# ldapadmin

LDAP 的网页管理界面（phpLDAPadmin）。查用户、改部门、重置密码都在这。

## 用途与端口

| 项 | 值 |
|---|---|
| 容器名 | `of-ldapadmin` |
| 固定 IP | `172.31.0.23` |
| 端口 | `80`（容器内，不发布到宿主） |
| 镜像 | `osixia/phpldapadmin:0.9.0@sha256:d112b82b…` |

## 入口与依赖

- **入口**：`https://ldapadmin.org-devops.com`，**已摘网关**（#86/#88：phpLDAPadmin
  自带 LDAP bind 就是唯一登录）。直接用目录管理员
  `cn=admin,dc=devops,dc=com` + `.env` 的 `LDAP_ADMIN_PASSWORD` 登录。
- **依赖谁**：`ldap`（所有数据都从它读）、`dnsmasq`、`oauth2-proxy`（网关鉴权）
- **被谁依赖**：无

> 历史遗留已关闭：M0 阶段它曾是无鉴权站点（靠网络可达性控制），#36 起改为网关鉴权，
> 未登录访问一律 302 到 `auth.<domain>/oauth2/start`。

## 部署与配置

```bash
docker compose up -d ldapadmin
```

登录用 LDAP 管理员：`cn=admin,dc=devops,dc=com` + `LDAP_ADMIN_PASSWORD`。
登录框里 Login DN 要写全，只写 `admin` 不行。

`PHPLDAPADMIN_LDAP_HOSTS=ldap` 让它连容器网络里的 `ldap` 这个名字——
所以 `dnsmasq` 挂了它也打不开登录页，症状是「页面出来了但登录转圈」。

## 关键环境变量

| 变量 | 作用 | 默认 |
|---|---|---|
| `PHPLDAPADMIN_LDAP_HOSTS` | 上游 LDAP 主机名 | `ldap` |
| `PHPLDAPADMIN_HTTPS` | 自己是否走 HTTPS | `false`（TLS 由网关终结） |

## 排查步骤

**1. 容器健康吗**

```bash
docker inspect -f '{{.State.Health.Status}}' of-ldapadmin
```

**2. 它自己活着吗**

```bash
docker compose exec -T ldapadmin php -r "echo file_get_contents('http://localhost/') === false ? 'FAIL' : 'OK';"
```

期望 `OK`。

**3. 走网关能打开吗**

```bash
curl -sS -k -o /dev/null -w '%{http_code}\n' --resolve ldapadmin.org-devops.com:443:127.0.0.1 https://ldapadmin.org-devops.com:443/
```

未登录期望 `302`（跳 oauth2 登录，#36）：

```bash
curl -sS -k -o /dev/null -w '%{redirect_url}\n' --resolve ldapadmin.org-devops.com:443:127.0.0.1 https://ldapadmin.org-devops.com:443/
```

`redirect_url` 应指向 `https://auth.org-devops.com/oauth2/start?rd=...`。
如果 `302` 都没有（直连 200 或连接失败），说明站点块没带 `forward_auth`，
查 `out/Caddyfile` 里 `https://ldapadmin.<domain>` 块和 `routes.yaml` 的 `auth: true`。
浏览器登录后再访问才会看到 phpLDAPadmin 页面（`grep phpLDAPadmin` 只在登录后有效）。

**4. 能连上 LDAP 吗（登录转圈时查这个）**

```bash
docker compose exec -T ldapadmin getent hosts ldap
docker compose exec -T ldapadmin php -r '$c=@fsockopen("ldap",389,$e,$s,3); echo $c?"LDAP-OK\n":"LDAP-FAIL $s\n";'
```

`LDAP-FAIL` 说明它到 ldap 的链路断了 → 查 dnsmasq 和 ldap 本身。

**5. 登录报错**

| 现象 | 原因 |
|---|---|
| `Invalid credentials` | DN 写错或密码不对。DN 必须写 `cn=admin,dc=devops,dc=com` |
| `Could not connect to LDAP server` | 第 4 步失败 |
| 页面空白 | PHP 报错被吞了，看 `docker compose logs ldapadmin` |

## 常用命令

```bash
# 重启
docker compose restart ldapadmin

# 页面标题自检
docker compose exec -T ldapadmin php -r "echo strip_tags(file_get_contents('http://localhost/')) === '' ? 'EMPTY' : 'OK';"

# 日志
docker compose logs --tail=50 ldapadmin
```

## 已知边界

- **管理面没有鉴权**，见上文。这是 M0 的已知遗留项，不是 bug
- 界面是 phpLDAPadmin 0.9.0，比较老，复杂 schema 编辑容易报错——批量操作建议直接用 `ldapadd` / `ldapmodify`

## 使用指南

```bash
docker compose up -d ldapadmin
curl -sS -k -o /dev/null -w '%{http_code} %{redirect_url}\n' \
  --resolve ldapadmin.org-devops.com:443:127.0.0.1 https://ldapadmin.org-devops.com:443/
docker compose logs --tail=50 ldapadmin
```

未登录期望 `302` 到 `auth.<domain>/oauth2/start`；登录后 Login DN 要写全
`cn=admin,dc=devops,dc=com`。

## 注意事项

- **两层登录**：先过网关 oauth2 / Dex，再是 phpLDAPadmin 自己的 LDAP bind；只写 `admin` 会 `Invalid credentials`（DN 必须写全）。
- `PHPLDAPADMIN_LDAP_HOSTS=ldap` 让它连容器网络里的 `ldap` 名字，**dnsmasq 挂了它也打不开登录页**，症状是「页面出来了但登录转圈」。
- #36 起改为网关鉴权，未登录一律 302；直连得到 200 说明站点块没带 `forward_auth`（查 `out/Caddyfile` 与 `config/routes.yaml` 的 `auth: true`）。
- 界面是 phpLDAPadmin 0.9.0，复杂 schema 编辑容易报错，批量操作建议直接用 `ldapadd` / `ldapmodify`。
- 认证域名只由 `config/routes.yaml` 里 `name: auth` 那条路由的 `subdomain` 决定，**没有 `AUTH_SUBDOMAIN` 变量**（`会话交接.md` §1.3）。

## 设置

| 真源 | 路径 / 变量 |
|---|---|
| 上游 LDAP 主机名 | `.env` 的 `PHPLDAPADMIN_LDAP_HOSTS`（默认 `ldap`） |
| 自身 TLS | `.env` 的 `PHPLDAPADMIN_HTTPS=false`（TLS 由网关终结） |
| 是否要登录 | `config/routes.yaml` 对应路由的 `auth: true` |
| 目录管理员 DN | `cn=admin,dc=devops,dc=com`（口令在 `.env` 的 `LDAP_ADMIN_PASSWORD`） |

没有独立配置文件；界面操作直接落到 `ldap` 容器的数据卷。

## 备份

ldapadmin **无数据卷**，所有目录数据在 `ldap` 容器，随 `ldap_data` / `ldap_config` 一起保管，
无需单独备份；凭据在 `.env`（不入库）。完整卷映射与恢复步骤见
[备份与恢复](../备份与恢复.md)。
