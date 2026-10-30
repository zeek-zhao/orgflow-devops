#!/usr/bin/env bash
# M0 一键部署：渲染路由 -> 起底座 -> （可选）推送 Job
set -euo pipefail

PUSH_JOBS=0
SERVICE=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --push-jobs) PUSH_JOBS=1; shift ;;
    --service)
      if [ "$#" -lt 2 ] || [ -z "$2" ]; then
        echo "--service 需要指定服务名" >&2
        exit 1
      fi
      SERVICE="$2"; shift 2 ;;
    *) echo "未知参数: $1" >&2; exit 1 ;;
  esac
done

if [ "$PUSH_JOBS" = 1 ]; then
  if [ -n "$SERVICE" ]; then
    echo "--push-jobs 不能与 --service 同用" >&2
    exit 1
  fi
  exec make jobs
fi

case "$SERVICE" in
  ""|jenkins|caddy|router|ldap|ldapadmin|dex|oauth2-proxy|nexus) ;;
  *) echo "不支持的服务: $SERVICE" >&2; exit 1 ;;
esac
case "${ENV_NAME:-dev}" in
  dev) ENV_FILE="${ENV_FILE:-.env}" ;;
  staging|prod) ENV_FILE="${ENV_FILE:-.env.${ENV_NAME}}" ;;
  *) echo "ENV_NAME 必须为 dev / staging / prod" >&2; exit 1 ;;
esac

if [ -n "${SERVICE_VERSION:-}" ]; then
  if [[ ! "$SERVICE_VERSION" =~ ^[a-zA-Z0-9_][a-zA-Z0-9_.-]{0,127}$ ]]; then
    echo "SERVICE_VERSION 不是合法的镜像 tag" >&2
    exit 1
  fi
  case "$SERVICE" in
    jenkins) export JENKINS_VERSION="$SERVICE_VERSION" ;;
    nexus) export NEXUS_VERSION="$SERVICE_VERSION" ;;
    *) echo "SERVICE_VERSION 仅支持 Jenkins/Nexus" >&2; exit 1 ;;
  esac
fi
if [ -n "${SERVICE_PORT:-}" ]; then
  if [ "$SERVICE" != caddy ] || [[ ! "$SERVICE_PORT" =~ ^[0-9]{1,5}$ ]] ||
     (( 10#$SERVICE_PORT < 1 || 10#$SERVICE_PORT > 65535 )); then
    echo "SERVICE_PORT 仅支持 Caddy 的 1-65535 网关端口" >&2
    exit 1
  fi
  export GATEWAY_PORT="$SERVICE_PORT"
fi
if [ -n "${SERVICE_DOMAIN:-}" ]; then
  echo "M0 不支持 SERVICE_DOMAIN 覆盖，请配置 routes/Caddy" >&2
  exit 1
fi

if [ ! -f "$ENV_FILE" ]; then
  echo "缺少 $ENV_FILE，先复制 .env.example 并填写（Job agent 也需配置）" >&2
  exit 1
fi

mkdir -p out
python3 services/router/render.py --routes config/routes.yaml --out out/Caddyfile

if [ -n "$SERVICE" ]; then
  echo "== 部署 $SERVICE (${ENV_NAME:-dev}) =="
  docker compose --env-file "$ENV_FILE" up -d --no-deps "$SERVICE"
  docker compose --env-file "$ENV_FILE" ps "$SERVICE"
  exit 0
fi

echo "== 启动 M0 底座 =="
docker compose --env-file "$ENV_FILE" up -d

echo "== 等待 Jenkins 就绪 =="
for i in $(seq 1 60); do
  if curl -fsS -o /dev/null "http://localhost:${GATEWAY_PORT:-8080}/jenkins/login" 2>/dev/null; then
    echo "Jenkins ready"
    break
  fi
  sleep 3
  if [ "$i" = 60 ]; then
    echo "Jenkins 未在预期时间内就绪" >&2
    exit 1
  fi
done

echo "== 完成。入口 http://localhost:${GATEWAY_PORT:-8080} =="
