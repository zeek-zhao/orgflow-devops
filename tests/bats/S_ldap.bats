#!/usr/bin/env bats
# S_ldap —— 匿名拒 / 管理员成功 / 宿主无 389（§8.1，独立命名空间）
# 变量：PFX 容器前缀(默认 of)、LDAP_BASE、LDAP_ADMIN、LDAP_PW。

@test "容器 healthy" {
  run docker inspect -f '{{.State.Health.Status}}' "${PFX:-of}-ldap"
  [ "$output" = "healthy" ]
}

@test "匿名 bind 被拒（ACL 生效）" {
  run docker exec "${PFX:-of}-ldap" ldapsearch -x -H ldap://127.0.0.1 -b "${LDAP_BASE:-dc=orgflow,dc=local}"
  [[ "$output" == *"Insufficient access"* || "$status" -ne 0 ]]
}

@test "管理员 bind 成功" {
  run docker exec -e PW="${LDAP_PW:-change-me}" "${PFX:-of}-ldap" sh -c "ldapsearch -x -H ldap://127.0.0.1 -D ${LDAP_ADMIN:-cn=admin,dc=orgflow,dc=local} -w \$PW -b ${LDAP_BASE:-dc=orgflow,dc=local}"
  [ "$status" -eq 0 ]
}

@test "宿主不映射 389" {
  run sh -c 'ss -lnt 2>/dev/null | grep -E ":389[[:space:]]" || true'
  [ -z "$output" ]
}
