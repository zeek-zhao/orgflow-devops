# ldapadmin 服务手册

## 1. 职责
目录管理端：LDAP Admin Web：ldap 可达时进管理页；连不上时降级为登录页并重试，不崩。

## 2. 配置
LDAP_HOST（默认 ldap）、BASE_DN；web 根目录 `/var/www/html`。

## 3. 启动
make up-ldapadmin（单起，隔离端口 8081）。容器名 `of-ldapadmin`，镜像按 `tests/images.lock` 的 digest 引用。

## 4. 健康检查
页面 200；ldap 不可达时返回登录页且容器健康。

## 5. 用例
tests/bats/S_ldapadmin.bats（健康/页面200/降级不崩）

## 6. 故障排查
一直登录页：ldap 不可达，检查 ldap 容器。。
