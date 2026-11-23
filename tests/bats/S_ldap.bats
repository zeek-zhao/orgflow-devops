#!/usr/bin/env bats
# S_ldap —— 匿名拒 / 管理员成功 / ACL 生效 / 宿主无 389

@test "容器 healthy" {
  run docker inspect -f '{{.State.Health.Status}}' of-ldap
  [ "$output" = "healthy" ]
}

@test "匿名 bind 被拒（ACL 生效）" {
  run docker exec of-ldap ldapsearch -x -H ldap://127.0.0.1 -b dc=orgflow,dc=local
  [[ "$output" == *"Insufficient access"* || "$status" -ne 0 ]]
}

@test "管理员 bind 成功" {
  run docker exec -e PW=change-me of-ldap sh -c 'ldapsearch -x -H ldap://127.0.0.1 -D cn=admin,dc=orgflow,dc=local -w $PW -b dc=orgflow,dc=local'
  [ "$status" -eq 0 ]
}

@test "宿主不映射 389" {
  run sh -c 'ss -lnt 2>/dev/null | grep -E ":389[[:space:]]" || true'
  [ -z "$output" ]
}
