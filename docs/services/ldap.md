# ldap 服务手册

> 状态：适用 | 最后核对：2026-11-24 | 对应分支：feat/m0-v2


## 1. 职责
身份目录：OpenLDAP 目录：首次用 LDIF 初始化（{SSHA} 口令 + ACL 匿名拒/管理员可写），宿主不映射 389。

## 2. 配置
DOMAIN、BASE_DN、LDAP_PASSWORD（真值走 .env，目录存 {SSHA}）、bootstrap.ldif.tmpl。

## 3. 启动
make up-ldap（单起，不占宿主 389）。容器名 `of-ldap`，镜像按 `tests/images.lock` 的 digest 引用。

## 4. 健康检查
匿名 ldapsearch 被拒；管理员 bind 成功。

## 5. 用例
tests/bats/S_ldap.bats（健康/匿名拒/管理员成功/宿主无389）

## 6. 故障排查
bind 返回 49：口令与 {SSHA} 不一致；目录空：检查首次初始化日志。。
