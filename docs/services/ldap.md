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

## 使用指南

```bash
docker compose up -d ldap
bash services/auth/bootstrap-ldif.sh            # 幂等，可放心重复跑
docker compose exec -T ldap ldapsearch -x -b dc=devops,dc=com -s sub "(objectClass=*)" dn | grep -c '^dn:'
make backup                                      # 只含 ldap_data
```

条目数基线 **33**；少于 33 是没导全，多于 33 是重复导入过。

## 注意事项

- `make backup` **只备 `ldap_data`，不含 `ldap_config`**（schema / `cn=config`）：全机丢失时必须另有同一停服时点的 `ldap_config` 副本，不能把数据包当完整灾备（[备份与恢复](../备份与恢复.md)「范围与前提」）。
- `departments.ldif` 有**悬空 member 引用**（指向不存在的 `ou=people`），属既有生产数据；导入脚本容忍它，查询会看到指向空 DN 的 member。
- 改 `LDAP_DOMAIN` 等于换 base DN，**已导入的数据会对不上**；除非重建不要动。
- `bootstrap-ldif.sh` 把 `ldapadd` 退出码 **68（entry already exists）当成功**——这是幂等的关键；密码走临时 600 文件 / stdin，不进进程表（最小披露）。
- 初始占位口令只在受控交付物中给出，不写进本仓库文档 / 脚本，首次登录即改（`M0-增量需求总表.md` §0 B-口令、§5 风险）；LDIF 里存哈希不存明文。
- `users.ldif` / `app.ldif` 历史上有无盐哈希、uidNumber 冲突、注释失真、无组账号等数据缺陷（`M0-增量需求总表.md` §2 现状取证）；改 LDIF 前先核对命名规范并跑 `make test`。

## 设置

| 真源 | 路径 / 变量 |
|---|---|
| 目录数据（LDIF） | `services/auth/ldif/*.ldif` |
| 幂等导入脚本 | `services/auth/bootstrap-ldif.sh` |
| base DN / 组织 | `.env` 的 `LDAP_DOMAIN` / `LDAP_ORGANISATION`（默认 `dc=devops,dc=com`） |
| 目录管理员口令 | `.env` 的 `LDAP_ADMIN_PASSWORD`（值不入库、不写文档） |
| 数据 / 配置卷 | `ldap_data`、`ldap_config` |

## 备份

`make backup` 产出的 LDAP 包只覆盖 `orgflow-devops_ldap_data`；**`orgflow-devops_ldap_config`
必须另行同刻保管**，恢复期间不要删这两个卷、不要重跑初始化导入。
恢复演练的验证点是「容器 healthy + 有权限的目录查询成功 + 条目数仍为 33 + 登录链路可用」，
`ldapsearch` 用 `-y /dev/stdin` 传密码、不输出条目正文。完整步骤见
[备份与恢复](../备份与恢复.md)。
