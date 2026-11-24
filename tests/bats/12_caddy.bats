#!/usr/bin/env bats
# 12_caddy —— 唯一入口 / admin 内网 / 公网路径（§8.3）

@test "caddy 容器 healthy" {
  run docker inspect -f '{{.State.Health.Status}}' "${PFX:-of}-caddy"
  [ "$output" = "healthy" ]
}

@test "admin 只绑内网 IP（127 不可达）" {
  run docker exec "${PFX:-of}-caddy" sh -c 'wget -q -O /dev/null http://127.0.0.1:2019/config/; echo $?'
  [ "$output" -ne 0 ]
  run docker exec "${PFX:-of}-caddy" curl -fsS -o /dev/null -w '%{http_code}' "http://${IP_CADDY:-192.168.90.10}:2019/config/"
  [ "$output" = "200" ]
}

@test "公网 handle：/healthz /status 200、根反代 homepage" {
  run docker exec "${PFX:-of}-caddy" sh -c "grep -q 'respond \"ok\" 200' /etc/caddy/Caddyfile && grep -q 'reverse_proxy homepage:3000' /etc/caddy/Caddyfile"
  [ "$status" -eq 0 ]
}

@test "公网无 /caddy/* 路由" {
  run docker exec "${PFX:-of}-caddy" sh -c "! grep -q 'handle_path /caddy' /etc/caddy/Caddyfile"
  [ "$status" -eq 0 ]
}
