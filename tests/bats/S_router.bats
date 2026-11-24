#!/usr/bin/env bats
# S_router —— /healthz 200 / 容器内 --render 渲染 / 公网 POST 403 / GET 405 / routes 脱敏
# 修复轮 T1：POST /render 仅允许容器内本机；宿主机端口调用应被 403。
# 变量：PFX 容器前缀、P_ROUTER 宿主端口。

@test "容器 healthy" {
  run docker inspect -f '{{.State.Health.Status}}' "${PFX:-of}-router"
  [ "$output" = "healthy" ]
}

@test "/healthz 200" {
  run curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${P_ROUTER:-8083}/healthz"
  [ "$output" = "200" ]
}

@test "公网/宿主机 POST /render → 403（T1 来源校验）" {
  run curl -s -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:${P_ROUTER:-8083}/render"
  [ "$output" = "403" ]
}

@test "容器内本机 --render 成功（路径型输出）" {
  run docker exec "${PFX:-of}-router" python3 /app/server.py --render
  [ "$status" -eq 0 ]
  [[ "$output" == *"reload ok"* || "$output" == *"幂等"* ]]
}

@test "容器内本机 POST /render → 200（回环白名单）" {
  run docker exec "${PFX:-of}-router" python3 -c "import urllib.request; r=urllib.request.Request('http://127.0.0.1:8080/render', data=b'', method='POST'); print(urllib.request.urlopen(r).status)"
  [ "$output" = "200" ]
}

@test "GET /render → 405（不得放宽为可用）" {
  run curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${P_ROUTER:-8083}/render"
  [ "$output" = "405" ]
}

@test "GET /routes 脱敏：无内网 IP 与证书路径" {
  run curl -s "http://127.0.0.1:${P_ROUTER:-8083}/routes"
  [[ "$output" != *"192.168."* ]]
  [[ "$output" != *"/ca/"* ]]
}
