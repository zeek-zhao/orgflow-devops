#!/usr/bin/env bats
# S_ldapadmin —— 容器健康 / 页面 200（§8.1，独立命名空间）
# 变量：PFX 容器前缀、P_LDAPADMIN 宿主端口。
# 注：旧「ldap 不可达降级」用例依赖不存在的 of-ldapadmin:local 镜像，已移除；
#     ldapadmin 的实际降级行为由服务手册与 14_ldapadmin.bats 覆盖。

@test "容器 healthy" {
  run docker inspect -f '{{.State.Health.Status}}' "${PFX:-of}-ldapadmin"
  [ "$output" = "healthy" ]
}

@test "页面 200" {
  run curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${P_LDAPADMIN:-8081}/"
  [ "$output" = "200" ]
}
