#!/usr/bin/env bats
# 14_ldapadmin —— LDAP Admin 页面（§8.3，独立命名空间，隔离端口）

@test "ldapadmin 容器 healthy" {
  run docker inspect -f '{{.State.Health.Status}}' "${PFX:-of}-ldapadmin"
  [ "$output" = "healthy" ]
}

@test "隔离端口页面 200" {
  run curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${P_LDAPADMIN:-8081}/"
  [ "$output" = "200" ]
}

@test "后端 LDAP host 来自环境变量（未写死）" {
  run docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "${PFX:-of}-ldapadmin"
  [[ "$output" == *"PHPLDAPADMIN_LDAP_HOSTS=ldap"* ]]
}
