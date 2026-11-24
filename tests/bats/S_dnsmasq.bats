#!/usr/bin/env bats
# S_dnsmasq —— 单服务用例（§8.1，独立命名空间）
# 变量：PFX=容器前缀(默认 of)、DOM=域名、DNS_IP、GW_IP。runner 注入 ofv2/*91 段。
# 用容器自带 dig（镜像装了 dnsutils），不依赖外部测试镜像。

@test "容器 healthy（仅起该服务时）" {
  run docker inspect -f '{{.State.Health.Status}}' "${PFX:-of}-dnsmasq"
  [ "$output" = "healthy" ]
}

@test "dig 自定义域返回 Caddy IP" {
  run docker exec "${PFX:-of}-dnsmasq" dig +short @127.0.0.1 "home.${DOM:-org-devops.local}"
  [ "$output" = "${GW_IP:-192.168.90.10}" ]
}

@test "未定义子域同样落 Caddy（通配）" {
  run docker exec "${PFX:-of}-dnsmasq" dig +short @127.0.0.1 "whatever.${DOM:-org-devops.local}"
  [ "$output" = "${GW_IP:-192.168.90.10}" ]
}

@test "非法域返回空（NXDOMAIN）" {
  run docker exec "${PFX:-of}-dnsmasq" dig +short @127.0.0.1 not-in-scope.example.com
  [ -z "$output" ]
}

@test "日志无 ERROR" {
  run docker logs "${PFX:-of}-dnsmasq"
  [[ "$output" != *ERROR* ]]
}
