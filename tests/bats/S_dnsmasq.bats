#!/usr/bin/env bats
# S_dnsmasq —— 单服务用例（方案 §4：只用该容器，能起/健康/端口/日志/配置解析）
# 用容器自带的 dig（镜像已装 dnsutils），不依赖外部测试镜像。

@test "容器 healthy" {
  run docker inspect -f '{{.State.Health.Status}}' of-dnsmasq
  [ "$output" = "healthy" ]
}

@test "dig 自定义域返回 Caddy IP（.10）" {
  run docker exec of-dnsmasq dig +short @127.0.0.1 home.org-devops.local
  [ "$output" = "192.168.90.10" ]
}

@test "未定义子域同样落 Caddy（通配）" {
  run docker exec of-dnsmasq dig +short @127.0.0.1 whatever.org-devops.local
  [ "$output" = "192.168.90.10" ]
}

@test "非法域返回空（NXDOMAIN）" {
  run docker exec of-dnsmasq dig +short @127.0.0.1 not-in-scope.example.com
  [ -z "$output" ]
}

@test "日志无 ERROR" {
  run docker logs of-dnsmasq
  [[ "$output" != *ERROR* ]]
}
