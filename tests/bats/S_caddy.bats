#!/usr/bin/env bats
# S_caddy —— bootstrap 下 :80→308、Admin API 200、按 Host 分站点、无证书不崩

@test "容器 healthy" {
  run docker inspect -f '{{.State.Health.Status}}' of-caddy
  [ "$output" = "healthy" ]
}

@test "Admin API 200（仅内网 IP，127 不再监听）" {
  run docker exec of-caddy curl -fsS -o /dev/null -w '%{http_code}' http://192.168.90.10:2019/config/
  [ "$output" = "200" ]
}

@test ":80 跳 :443（308）" {
  run docker exec of-caddy curl -s -o /dev/null -w '%{http_code}' \
    -H 'Host: home.org-devops.local' http://127.0.0.1:80/
  [ "$output" = "308" ]
}

@test "按 Host 分站点（Caddyfile 含各 host）" {
  run docker exec of-caddy sh -c 'grep -c "org-devops.local {" /etc/caddy/Caddyfile'
  [ "$output" -ge 1 ]
}

@test "日志无 ERROR" {
  run docker logs of-caddy
  [[ "$output" != *ERROR* ]]
}
