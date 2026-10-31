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

- **入口**：`https://ldapadmin.org-devops.com`，**不需要登录**（`routes.yaml` 里没有 `auth: true`）
- **依赖谁**：`ldap`（所有数据都从它读）、`dnsmasq`
- **被谁依赖**：无

**这是个反直觉的地方**：管理界面自己不设防，能打开就能改数据。之所以这么定，是因为
M0 阶段网关还没配好「管理面单独鉴权」，先靠网络可达性控制（只有能连到网关的机器才访问得到）。
上生产前必须改成 `auth: true` 或加 IP 白名单——这一条写在 `docs/M0-最小核心.md` 的遗留项里。

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

期望 `200`，且页面里有 `phpLDAPadmin` 字样：

```bash
curl -sS -k --resolve ldapadmin.org-devops.com:443:127.0.0.1 https://ldapadmin.org-devops.com:443/ | grep -c phpLDAPadmin
```

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
