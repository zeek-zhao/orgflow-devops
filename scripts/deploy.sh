#!/usr/bin/env bash
# M0 一键部署：渲染路由 -> 起底座 -> （可选）推送 Job
set -euo pipefail

PUSH_JOBS=0
[ "${1:-}" = "--push-jobs" ] && PUSH_JOBS=1

if [ ! -f .env ]; then
  echo "缺少 .env，先 cp .env.example .env 并填写" >&2
  exit 1
fi

mkdir -p out
python3 services/router/render.py --routes config/routes.yaml --out out/Caddyfile

echo "== 启动 M0 底座 =="
docker compose --env-file .env up -d

echo "== 等待 Jenkins 就绪 =="
for i in $(seq 1 60); do
  if curl -fsS -o /dev/null "http://localhost:${GATEWAY_PORT:-8080}/jenkins/login" 2>/dev/null; then
    echo "Jenkins ready"
    break
  fi
  sleep 3
  [ "$i" = 60 ] && echo "警告：Jenkins 未在预期时间内就绪" >&2
done

if [ "$PUSH_JOBS" = "1" ]; then
  echo "== 推送参数化 Job =="
  if command -v jenkins-jobs >/dev/null 2>&1; then
    jenkins-jobs --conf config/jenkins_jobs.ini update config/job_definitions/
  else
    echo "未找到 jenkins-jobs，请在 dev 容器内执行：" >&2
    echo "  jenkins-jobs --conf config/jenkins_jobs.ini update config/job_definitions/" >&2
  fi
fi

echo "== 完成。入口 http://localhost:${GATEWAY_PORT:-8080} =="
