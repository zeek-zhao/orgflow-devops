#!/usr/bin/env bash
# M0 自举：初始化环境 -> 渲染路由 -> 分批启动并等待健康 -> 端点自检
set -euo pipefail
set +x
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
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
  ""|dnsmasq|jenkins|caddy|router|ldap|ldapadmin|dex|oauth2-proxy|nexus) ;;
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
  echo "SERVICE_PORT 已废弃（ADR-13 域名路由）：请在 $ENV_FILE 设置 GATEWAY_HTTP_PORT / GATEWAY_HTTPS_PORT" >&2
  exit 1
fi
if [ -n "${SERVICE_DOMAIN:-}" ]; then
  echo "SERVICE_DOMAIN 已废弃（ADR-13 域名路由）：请在 $ENV_FILE 设置 GATEWAY_DOMAIN" >&2
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

HEALTH_TIMEOUT="${DEPLOY_HEALTH_TIMEOUT:-600}"
POLL_INTERVAL="${DEPLOY_POLL_INTERVAL:-3}"
for value in "$HEALTH_TIMEOUT" "$POLL_INTERVAL"; do
  if [[ ! "$value" =~ ^[1-9][0-9]{0,5}$ ]]; then
    echo "DEPLOY_HEALTH_TIMEOUT / DEPLOY_POLL_INTERVAL 必须为正整数秒（最多六位）" >&2
    exit 1
  fi
done

COMPOSE_COMMAND+=(--env-file "$ENV_FILE")

# 域名是渲染的输入：先解析 Compose 得到 GATEWAY_DOMAIN，再渲染 Caddyfile / dex 配置。
# 顺序反了的话，.env 改了域名而 Caddyfile 仍按 routes.yaml 的默认值生成。
if ! DEPLOY_CONFIG="$("${COMPOSE_COMMAND[@]}" config --format json 2>/dev/null)"; then
  echo "Compose 配置解析失败，请检查 $ENV_FILE 和 docker-compose.yml（错误正文可能含密钥，不输出）" >&2
  exit 1
fi
GATEWAY_DOMAIN="$(printf '%s' "$DEPLOY_CONFIG" | python3 -c '
import json, sys
config = json.load(sys.stdin)
env = config["services"]["router"].get("environment") or {}
print(env.get("GATEWAY_DOMAIN") or "org-devops.com")
')"
AUTH_SUBDOMAIN="$(printf '%s' "$DEPLOY_CONFIG" | python3 -c '
import json, sys
config = json.load(sys.stdin)
env = config["services"]["router"].get("environment") or {}
print(env.get("AUTH_SUBDOMAIN") or "auth")
')"
HTTPS_PORT="$(printf '%s' "$DEPLOY_CONFIG" | python3 -c '
import json, sys
ports = json.load(sys.stdin)["services"]["caddy"]["ports"]
print(next(p["published"] for p in ports if p["target"] == 443))
')"
HTTP_PORT="$(printf '%s' "$DEPLOY_CONFIG" | python3 -c '
import json, sys
ports = json.load(sys.stdin)["services"]["caddy"]["ports"]
print(next(p["published"] for p in ports if p["target"] == 80))
')"

mkdir -p out
export GATEWAY_DOMAIN AUTH_SUBDOMAIN
python3 services/router/render.py --routes config/routes.yaml --out out/Caddyfile --admin ""

# dex 的 issuer / redirectURI 必须是浏览器可达的绝对 URL，按当前域名渲染
if ! ENV_FILE="$ENV_FILE" GATEWAY_DOMAIN="$GATEWAY_DOMAIN" \
     bash "$ROOT/scripts/render-dex.sh" >/dev/null; then
  echo "dex 配置渲染失败（scripts/render-dex.sh）" >&2
  exit 1
fi

if [ -n "$SERVICE" ]; then
  echo "== 部署 $SERVICE (${ENV_NAME:-dev}) =="
  "${COMPOSE_COMMAND[@]}" up -d --no-deps "$SERVICE"
  "${COMPOSE_COMMAND[@]}" ps "$SERVICE"
  exit 0
fi

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

# dnsmasq 必须最先起来：其余服务都配了 dns: 172.31.0.2
start_batch dnsmasq
start_batch ldap
start_batch dex oauth2-proxy
start_batch router caddy
start_batch jenkins nexus ldapadmin
wait_healthy dnsmasq ldap dex oauth2-proxy router caddy jenkins nexus ldapadmin

# 域名路由：所有自检都带 SNI/Host，走 127.0.0.1 的映射端口
gw() {   # gw <子域> <路径> → HTTP 状态码
  curl -sSk --connect-timeout 5 --max-time 10 -o /dev/null -w '%{http_code}' \
    --resolve "$1.${GATEWAY_DOMAIN}:${HTTPS_PORT}:127.0.0.1" \
    "https://$1.${GATEWAY_DOMAIN}$2"
}

for check in "auth /ping 200" "jenkins / 302"; do
  read -r sub path expected <<< "$check"
  url="https://${sub}.${GATEWAY_DOMAIN}${path}"
  if ! actual="$(gw "$sub" "$path")"; then
    echo "端点自检连接失败: $url（宿主端口 ${HTTPS_PORT}）" >&2
    diagnose caddy oauth2-proxy
    exit 1
  fi
  if [ "$actual" != "$expected" ]; then
    echo "端点自检失败: $url，预期 $expected，实际 $actual" >&2
    diagnose caddy oauth2-proxy
    exit 1
  fi
  echo "端点自检通过: $url = $actual"
done

echo "== 部署完成：全部服务 healthy =="
echo "网关端口：HTTP ${HTTP_PORT} / HTTPS ${HTTPS_PORT}（宿主映射）"
echo "访问入口（需要先让域名解析到本机）："
echo "  https://jenkins.${GATEWAY_DOMAIN}/     受保护，未登录 302 是认证跳转"
echo "  https://nexus.${GATEWAY_DOMAIN}/"
echo "  https://ldapadmin.${GATEWAY_DOMAIN}/"
echo "  https://auth.${GATEWAY_DOMAIN}/ping    认证网关"
echo "  https://dex.${GATEWAY_DOMAIN}/dex/     OIDC"
echo "域名解析：bash scripts/gen-hosts.sh      生成 /etc/hosts 片段"
echo "证书信任：bash scripts/ca-install.sh     安装 Caddy 内部 CA 根证书"
echo "下一步: make jobs（先配置 Jenkins 插件、API 管理入口及 GitHub 凭据）"
echo "Jenkins 管理员密码在 $ENV_FILE 的 JENKINS_ADMIN_PASSWORD"
