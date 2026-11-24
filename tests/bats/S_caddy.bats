#!/usr/bin/env bats
# S_caddy —— Admin API 内网可达 / :80→308 / 按域名分站点 / 公网占根（§8.1）
# 变量：PFX 容器前缀、IP_CADDY admin 内网 IP、DOM 域名。

@test "容器 healthy" {
  run docker inspect -f '{{.State.Health.Status}}' "${PFX:-of}-caddy"
  [ "$output" = "healthy" ]
}

@test "Admin API 200（仅内网 IP）" {
  run docker exec "${PFX:-of}-caddy" curl -fsS -o /dev/null -w '%{http_code}' "http://${IP_CADDY:-192.168.90.10}:2019/config/"
  [ "$output" = "200" ]
}

@test ":80 跳 :443（308）" {
  run docker exec "${PFX:-of}-caddy" curl -s -o /dev/null -w '%{http_code}' \
    -H "Host: home.${DOM:-org-devops.local}" http://127.0.0.1:80/
  [ "$output" = "308" ]
}

@test "按 Host 分站点（Caddyfile 含各 host）" {
  run docker exec "${PFX:-of}-caddy" sh -c "grep -c '${DOM:-org-devops.local} {' /etc/caddy/Caddyfile"
  [ "$output" -ge 1 ]
}

@test "公网入口 HomePage 占根（handle 反代 homepage）" {
  run docker exec "${PFX:-of}-caddy" sh -c "grep -A2 'handle {' /etc/caddy/Caddyfile | grep -q 'homepage:3000'"
  [ "$status" -eq 0 ]
}

@test "日志无 ERROR" {
  run docker logs "${PFX:-of}-caddy"
  [[ "$output" != *ERROR* ]]
}
