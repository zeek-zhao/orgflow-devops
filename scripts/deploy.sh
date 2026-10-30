#!/usr/bin/env bash
# M0 自举：初始化环境 -> 渲染路由 -> 分批启动并等待健康 -> 端点自检
set -euo pipefail
set +x
read -r -a COMPOSE_COMMAND <<< "${COMPOSE:-docker compose}"

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
    jenkins|nexus)
      locked_ref="$(awk -F '\t' -v service="$SERVICE" '$1 == service {print $2}' tests/images.lock)"
      if [ "${locked_ref##*:}" != "$SERVICE_VERSION" ]; then
        echo "SERVICE_VERSION 必须匹配 tests/images.lock；升级请先更新 digest 锁定" >&2
        exit 1
      fi
      ;;
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
  if [ -n "$SERVICE" ] || [ "$ENV_FILE" != .env ] || [ "${ENV_NAME:-dev}" != dev ]; then
    echo "缺少 $ENV_FILE；单服务/非 dev 部署需预先配置环境文件" >&2
    exit 1
  fi
  python3 - "$ENV_FILE" <<'PY'
import os
from pathlib import Path
import secrets
import string
import sys

values = {key: secrets.token_hex(32) for key in (
    "JENKINS_ADMIN_PASSWORD", "LDAP_ADMIN_PASSWORD", "OAUTH2_CLIENT_SECRET",
)}
# 32 printable ASCII bytes; also a valid oauth2-proxy base64 cookie secret.
values["OAUTH2_COOKIE_SECRET"] = "".join(
    secrets.choice(string.ascii_letters + string.digits + "-_") for _ in range(32)
)
lines = Path(".env.example").read_text().splitlines(keepends=True)
found = set()
for index, line in enumerate(lines):
    key = line.partition("=")[0]
    if key in values:
        lines[index] = f"{key}={values[key]}\n"
        found.add(key)
if found != values.keys():
    sys.exit(".env.example 缺少必需的密钥字段")
fd = os.open(sys.argv[1], os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
with os.fdopen(fd, "w") as handle:
    handle.write("".join(lines))
print("已生成随机密钥，已写入 .env，请妥善保存（不在终端显示密码）。")
PY
fi

mkdir -p out
python3 services/router/render.py --routes config/routes.yaml --out out/Caddyfile --admin ""
COMPOSE_COMMAND+=(--env-file "$ENV_FILE")

if [ -n "$SERVICE" ]; then
  echo "== 部署 $SERVICE (${ENV_NAME:-dev}) =="
  "${COMPOSE_COMMAND[@]}" up -d --no-deps "$SERVICE"
  "${COMPOSE_COMMAND[@]}" ps "$SERVICE"
  exit 0
fi

HEALTH_TIMEOUT="${DEPLOY_HEALTH_TIMEOUT:-600}"
POLL_INTERVAL="${DEPLOY_POLL_INTERVAL:-3}"
for value in "$HEALTH_TIMEOUT" "$POLL_INTERVAL"; do
  if [[ ! "$value" =~ ^[1-9][0-9]{0,5}$ ]]; then
    echo "DEPLOY_HEALTH_TIMEOUT / DEPLOY_POLL_INTERVAL 必须为正整数秒（最多六位）" >&2
    exit 1
  fi
done

if ! DEPLOY_CONFIG="$("${COMPOSE_COMMAND[@]}" config --format json 2>/dev/null)"; then
  echo "Compose 配置解析失败，请检查 $ENV_FILE 和 docker-compose.yml（错误正文可能含密钥，不输出）" >&2
  exit 1
fi
GATEWAY_PORT="$(printf '%s' "$DEPLOY_CONFIG" | python3 -c '
import json, sys
ports = json.load(sys.stdin)["services"]["caddy"]["ports"]
print(next(p["published"] for p in ports if p["target"] == 8080))
')"

# Compose logs may contain credentials, including values supplied by the caller.
redact() {
  DEPLOY_CONFIG="$DEPLOY_CONFIG" python3 -c '
import json, os, sys
config = json.loads(os.environ["DEPLOY_CONFIG"])
secrets = set()
for service in config["services"].values():
    for key, value in service.get("environment", {}).items():
        if value and any(word in key.upper() for word in ("PASSWORD", "SECRET", "TOKEN")):
            secrets.add(str(value))
    for arg in service.get("command") or []:
        key, sep, value = arg.partition("=")
        if sep and value and any(word in key.lower() for word in ("password", "secret", "token")):
            secrets.add(value)
for line in sys.stdin:
    for secret in sorted(secrets, key=len, reverse=True):
        line = line.replace(secret, "[REDACTED]")
    sys.stdout.write(line)
    sys.stdout.flush()
'
}

diagnose() {
  echo "== 部署失败；相关服务: $* ==" >&2
  {
    "${COMPOSE_COMMAND[@]}" ps -a || echo "无法读取 docker compose ps" >&2
    "${COMPOSE_COMMAND[@]}" logs --tail=50 "$@" || echo "无法读取服务日志" >&2
  } 2>&1 | redact >&2
  echo "若尚未创建容器，则无日志；请查看上方对应服务的拉取/构建/启动错误。" >&2
}

wait_healthy() {
  local deadline=$((SECONDS + HEALTH_TIMEOUT))
  local svc id status pending
  while :; do
    pending=""
    for svc in "$@"; do
      if ! id="$("${COMPOSE_COMMAND[@]}" ps -a -q "$svc" 2>&1)"; then
        printf '%s\n' "$id" | redact >&2
        diagnose "$svc"
        return 1
      fi
      if [ -z "$id" ]; then
        echo "$svc: 未创建容器" >&2
        diagnose "$svc"
        return 1
      fi
      if ! status="$(docker inspect -f '{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{else}}missing-healthcheck{{end}}' "$id" 2>&1)"; then
        printf '%s\n' "$status" | redact >&2
        diagnose "$svc"
        return 1
      fi
      if [ "$status" != "running healthy" ]; then
        pending+="$svc ($status); "
        case "$status" in
          *missing-healthcheck*|exited*|dead*|*unhealthy*)
            echo "$svc: $status" >&2
            diagnose "$svc"
            return 1
            ;;
        esac
      fi
    done
    if [ -z "$pending" ]; then
      echo "== healthy: $* =="
      return 0
    fi
    if (( SECONDS >= deadline )); then
      echo "健康等待超时（${HEALTH_TIMEOUT}s）: $pending" >&2
      diagnose "$@"
      return 1
    fi
    echo "等待健康: $pending"
    sleep "$POLL_INTERVAL"
  done
}

start_batch() {
  local svc
  echo "== 启动批次: $* =="
  for svc in "$@"; do
    echo "-- 拉取/构建/启动 $svc"
    if ! "${COMPOSE_COMMAND[@]}" up -d --no-deps --build --quiet-pull "$svc" 2>&1 | redact; then
      diagnose "$svc"
      return 1
    fi
  done
  wait_healthy "$@"
}

start_batch ldap
start_batch dex oauth2-proxy
start_batch router caddy
start_batch jenkins nexus ldapadmin
wait_healthy ldap dex oauth2-proxy router caddy jenkins nexus ldapadmin

BASE_URL="http://localhost:$GATEWAY_PORT"
for check in "/auth/ping 200" "/jenkins 302"; do
  read -r path expected <<< "$check"
  if ! actual="$(curl -sS --connect-timeout 5 --max-time 10 -o /dev/null -w '%{http_code}' "$BASE_URL$path")"; then
    echo "端点自检连接失败: $BASE_URL$path" >&2
    diagnose caddy oauth2-proxy
    exit 1
  fi
  if [ "$actual" != "$expected" ]; then
    echo "端点自检失败: $BASE_URL$path，预期 $expected，实际 $actual" >&2
    diagnose caddy oauth2-proxy
    exit 1
  fi
  echo "端点自检通过: $path = $actual"
done

echo "== 部署完成：全部服务 healthy =="
echo "访问入口: $BASE_URL"
echo "受保护路径: $BASE_URL/jenkins（未登录 302 是认证跳转，不是 Jenkins 就绪信号）"
echo "下一步: make jobs（先配置 Jenkins 插件、API 管理入口及 GitHub 凭据）"
echo "Jenkins 管理员密码在 $ENV_FILE 的 JENKINS_ADMIN_PASSWORD"
