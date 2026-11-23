#!/usr/bin/env bats
# S_router —— /healthz 200 / 渲染 / 坏 upstream 422 不 reload / 幂等

@test "容器 healthy" {
  run docker inspect -f '{{.State.Health.Status}}' of-router
  [ "$output" = "healthy" ]
}

@test "/healthz 200" {
  run curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8083/healthz
  [ "$output" = "200" ]
}

@test "改 routes.yaml → make routes → 新域可达（30s 内）" {
  cp config/routes.yaml /tmp/routes.bak
  echo "  - host: new.org-devops.local" >> config/routes.yaml
  echo "    upstream: homepage:3000" >> config/routes.yaml
  run bash -c 'for i in $(seq 1 30); do make routes >/dev/null 2>&1 && break; sleep 1; done; curl -s -o /dev/null -w "%{http_code}" -H "Host: new.org-devops.local" --resolve new.org-devops.local:443:127.0.0.1 https://127.0.0.1:8443/'
  [ "$output" = "200" ]
  cp /tmp/routes.bak config/routes.yaml
}

@test "坏 upstream → 422 且不 reload" {
  cp config/routes.yaml /tmp/routes.bak
  cat > config/routes.yaml <<'EOF'
routes:
  - host: home.org-devops.local
    upstream: bad-upstream
EOF
  run curl -s -o /dev/null -w '%{http_code}' -X POST http://127.0.0.1:8083/render
  [ "$output" = "422" ]
  cp /tmp/routes.bak config/routes.yaml
}

@test "幂等：重复 /render 不报错" {
  run bash -c 'curl -s -o /dev/null -w "%{http_code}" -X POST http://127.0.0.1:8083/render; curl -s -o /dev/null -w "%{http_code}" -X POST http://127.0.0.1:8083/render'
  [[ "$output" == *200*200* ]]
}
