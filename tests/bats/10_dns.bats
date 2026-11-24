#!/usr/bin/env bats
# 10_dns —— DNS 解析（§8.3，独立命名空间 ofv2-dnsmasq）
# 变量：PFX 容器前缀、DOM 域名、GW_IP 期望 Caddy IP。runner 注入 ofv2/orgflow-v2-net。

@test "dnsmasq 容器 healthy" {
  run docker inspect -f '{{.State.Health.Status}}' "${PFX:-of}-dnsmasq"
  [ "$output" = "healthy" ]
}

@test "dig @dnsmasq 有应答且指向 Caddy IP" {
  run docker exec "${PFX:-of}-dnsmasq" dig +short "@${DNS_IP:-127.0.0.1}" "home.${DOM:-org-devops.local}"
  [ -n "$output" ]
  [ "$output" = "${GW_IP:-192.168.90.10}" ]
}

@test "通配子域同样解析" {
  run docker exec "${PFX:-of}-dnsmasq" dig +short "@${DNS_IP:-127.0.0.1}" "x.y.${DOM:-org-devops.local}"
  [ "$output" = "${GW_IP:-192.168.90.10}" ]
}
