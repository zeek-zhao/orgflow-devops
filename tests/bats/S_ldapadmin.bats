#!/usr/bin/env bats
# S_ldapadmin —— 容器健康 / 页面 200 / ldap 不可达时降级

@test "容器 healthy" {
  run docker inspect -f '{{.State.Health.Status}}' of-ldapadmin
  [ "$output" = "healthy" ]
}

@test "页面 200" {
  run curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8081/
  [ "$output" = "200" ]
}

@test "ldap 不可达时降级为登录页（不崩）" {
  # 独立起一个指向不存在 host 的 ldapadmin，确认仍 200
  run docker run --rm -d --name of-ldapadmin-degrade \
    -e LDAP_HOST=nonexistent -e BASE_DN=dc=orgflow,dc=local \
    -p 8089:8080 of-ldapadmin:local
  sleep 1
  run curl -s http://127.0.0.1:8089/
  [[ "$output" == *"等待目录"* || "$output" == *"LDAP Admin"* ]]
  docker rm -f of-ldapadmin-degrade >/dev/null 2>&1 || true
}
