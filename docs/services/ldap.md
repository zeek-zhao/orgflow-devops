# ldap

目录服务。存用户、部门、应用账号。是整个权限体系的**数据源头**——Dex 从它读用户，其它服务不直接连它。

## 用途与端口

| 项 | 值 |
|---|---|
| 容器名 | `of-ldap` |
| 固定 IP | `172.31.0.22` |
| 端口 | `389`（ldap）、`636`（ldaps，未启用） |
| 镜像 | `osixia/openldap:1.5.0@sha256:18742e9c…` |
| 卷 | `ldap_data`（数据）、`ldap_config`（slapd 配置） |

**两个卷要分清**：`ldap_data` 是目录数据，`ldap_config` 是 slapd 自己的配置（schema、acl）。
`make backup` **只备 `ldap_data`**——完整灾备要另外保管 `ldap_config`，手册里已标注。

## 入口与依赖

- **入口**：不对外暴露。`ldapadmin` 是它的界面，`dex` 是它的消费者
- **依赖谁**：`dnsmasq`
- **被谁依赖**：`dex`（登录时查用户）、`ldapadmin`（管理界面）、`jenkins`（建 Job 时用管理员账号）

## 部署与配置

```bash
docker compose up -d ldap
```

| 项 | 值 |
|---|---|
| base DN | `dc=devops,dc=com`（**沿用既有生产 LDIF，不要改**） |
| 管理员 | `cn=admin,dc=devops,dc=com` |
| 组织名 | `LDAP_ORGANISATION`，默认 `OrgFlow` |

导入用户数据：

```bash
bash services/auth/bootstrap-ldif.sh          # 幂等，重复跑不会重复导入
bash services/auth/bootstrap-ldif.sh --dry-run
```

脚本把 `ldapadd` 的退出码 **68（entry already exists）当成成功**——这是幂等的关键。
其它任何错误都立即中止，不会留半截数据。密码走临时 600 文件传，不进进程表。

## 关键环境变量

| 变量 | 作用 | 默认 |
|---|---|---|
| `LDAP_ORGANISATION` | 组织名，写进 base DN 的 `o=` | `OrgFlow` |
| `LDAP_DOMAIN` | 决定 base DN 为 `dc=<第一段>,dc=<第二段>` | `devops.com` |
| `LDAP_ADMIN_PASSWORD` | `cn=admin` 的密码，**必填** | 无 |

改 `LDAP_DOMAIN` 等于换 base DN，**已导入的数据会对不上**。除非重建，不要动它。

## 排查步骤

**1. 容器健康吗**

```bash
docker inspect -f '{{.State.Health.Status}}' of-ldap
```

**2. 能绑上吗**

```bash
docker compose exec -T ldap ldapwhoami -x -H ldap://localhost -D "cn=admin,dc=devops,dc=com" -w "$LDAP_ADMIN_PASSWORD"
```

期望输出 `dn:cn=admin,dc=devops,dc=com`。`Invalid credentials` 是密码不对；
`Can't contact LDAP server` 是服务没起。

**3. 数据在吗（条目数是最快的判据）**

```bash
docker compose exec -T ldap ldapsearch -x -b dc=devops,dc=com -s sub "(objectClass=*)" dn | grep -c '^dn:'
```

期望 **34**（2026-11-05 起含 `rdsw`；此前是 33。加 1 个账号就 +1；少于说明 LDIF 没导全，多于说明重复导入过）（脚本本该拦住，值得查）。

**4. 某个用户在吗**

```bash
docker compose exec -T ldap ldapsearch -x -b dc=devops,dc=com "(uid=admin.zeek)" uid mail
```

返回空说明这个用户不存在——Dex 登录会报「用户不存在」，但界面上的错误信息不会告诉你是 LDAP 的问题。

**5. 从别的容器通吗**

```bash
docker compose exec -T dex getent hosts ldap
docker compose exec -T dex ldapsearch -x -H ldap://ldap:389 -b dc=devops,dc=com -s base "(objectClass=*)" dn
```

第二条能返回 base DN 说明 dex 到 ldap 的链路通。这条不通而第 2 步通 → DNS 问题，查 dnsmasq。

**6. 数据卷写满了吗**

```bash
docker compose exec -T ldap df -h /var/lib/ldap
```

## 常用命令

```bash
# 重启
docker compose restart ldap

# 幂等导入（可以放心重复跑）
bash services/auth/bootstrap-ldif.sh

# 只看条目数
docker compose exec -T ldap ldapsearch -x -b dc=devops,dc=com -s sub "(objectClass=*)" dn | grep -c '^dn:'

# 备份（只含 ldap_data）
make backup
```

## 已知边界

- **`departments.ldif` 里有悬空引用**：部分 `member` 指向不存在的 `ou=people`。这是既有生产数据的问题，
  导入脚本容忍它，但查询时会看到指向空 DN 的 member
- 没有启用 TLS（`636`）。容器网络内部通信，M1 再上
- `ldap_config` 不在备份范围内
