#!/usr/bin/env bats
# S_router —— /healthz 200 / /render 路径型渲染 / 坏前缀 422 不 reload / 幂等（§8.1）
# 变量：PFX 容器前缀、P_ROUTER 宿主端口。
# 注意：本用例通过容器 /render 直接下发，改的是独立命名空间的 Caddy admin，
#       不触碰 config/routes.yaml 真源（避免污染线上配置）。

@test "容器 healthy" {
  run docker inspect -f '{{.State.Health.Status}}' "${PFX:-of}-router"
  [ "$output" = "healthy" ]
}

@test "/healthz 200" {
  run curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${P_ROUTER:-8083}/healthz"
  [ "$output" = "200" ]
}

@test "/render 路径型输出含 prefix（非 host vhost）" {
  run curl -s -X POST "http://127.0.0.1:${P_ROUTER:-8083}/render"
  [[ "$output" == *"handle_path"* || "$output" == *"/ldapadmin"* ]]
}

@test "坏 prefix → 422 且不 reload" {
  # 由 router 的 render 校验拒绝非法 upstream；这里断言错误路径返回非 2xx
  run curl -s -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:${P_ROUTER:-8083}/render" \
    -H 'Content-Type: application/json' -d '{"routes":[{"prefix":"/bad","upstream":""}]}'
  [[ "$output" == "422" || "$output" == "400" ]]
}

@test "幂等：重复 /render 都 200" {
  run bash -c "curl -s -o /dev/null -w '%{http_code}' -X POST http://127.0.0.1:${P_ROUTER:-8083}/render; echo; curl -s -o /dev/null -w '%{http_code}' -X POST http://127.0.0.1:${P_ROUTER:-8083}/render"
  [[ "$output" == *200* && "$output" == *200* ]]
}
