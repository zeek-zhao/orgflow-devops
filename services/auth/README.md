# 权限管理服务（M0）

三件套，编排在主 `docker-compose.yml`：

| 组件 | 镜像 | 作用 |
|---|---|---|
| `ldap` | osixia/openldap | 统一目录（用户/部门/角色） |
| `ldapadmin` | osixia/phpldapadmin | 可视化用户/组管理台（`/ldapadmin`） |
| `oauth2-proxy` | quay.io/oauth2-proxy/oauth2-proxy | 统一认证网关（前置到 Caddy，`/auth`） |

## 初始化目录数据

把 `devops` 仓的 LDIF 导入：

```bash
docker compose exec -T ldap ldapadd -x -D "cn=admin,dc=orgflow,dc=internal" \
  -w "$LDAP_ADMIN_PASSWORD" -f /container/service/slapd/assets/config/bootstrap/ldif/custom/app.ldif
```

> M0 先跑通「LDAP 可登录 + Admin 可管理」；OAuth2 Proxy 的 OIDC provider 接入（对接 LDAP 或外部 IdP）作为 M0 收尾项。

## 保护范围（M0）

- 先保护 `/jenkins`、`/nexus`、`/ldapadmin`。
- 直连 Jenkins 应急端口保留（`127.0.0.1`），避免 proxy 配错锁死入口。

## 验收

- 未登录访问受保护路径 → 302 到登录；登录后放行。
- LDAP Admin 可增删用户/组。
