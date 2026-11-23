#!/usr/bin/env bash
# boot.sh —— 顺序启动编排（REQ-MIN-01/10/11）
#   up          按 §1.3 顺序逐步起 + 就绪断言，任一步失败即中止（带依赖诊断码）
#   up-<svc>    单服务独立启动（服务级 compose + 隔离端口，零依赖可起）
#   down-<svc>  单服务停止
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
COMPOSE="docker compose --env-file config/defaults.env -f docker-compose.yml"

# 启动顺序与前置依赖（§1.3）
ORDER=(dnsmasq certs-init ldap caddy homepage ldapadmin router)
declare -A DEPS=(
  [dnsmasq]=""
  [certs-init]=""
  [ldap]=""
  [caddy]="certs-init"
  [homepage]="caddy"
  [ldapadmin]="ldap caddy"
  [router]="caddy homepage ldapadmin"
)
declare -A DIAG=(
  [caddy]="D003 caddy 依赖 certs-init 未就绪"
  [homepage]="D005 homepage 依赖 caddy 未就绪"
  [ldapadmin]="D006 ldapadmin 依赖 ldap/caddy 未就绪"
  [router]="D007 router 依赖 caddy/homepage/ldapadmin 未就绪"
)

svc_healthy() {
  local svc="$1" cid state
  # 按容器名查（全栈与单起的容器名一致 of-<svc>），兼容两种启动方式
  cid="$(docker ps -q -f "name=^of-${svc}$" 2>/dev/null | head -1)"
  [[ -z "$cid" ]] && cid="$($COMPOSE ps -q "$svc" 2>/dev/null | head -1)"
  [[ -z "$cid" ]] && return 1
  state="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}running{{end}}' "$cid" 2>/dev/null)"
  [[ "$state" == "healthy" || "$state" == "running" ]]
}

dep_ready() {
  local svc="$1" dep
  for dep in ${DEPS[$svc]:-}; do
    # certs-init 是一次性容器：以 exit 0 为就绪
    if [[ "$dep" == "certs-init" ]]; then
      local cid="$($COMPOSE ps -a -q certs-init 2>/dev/null | head -1)"
      [[ -n "$cid" && "$(docker inspect -f '{{.State.ExitCode}}' "$cid" 2>/dev/null)" == "0" ]] || return 1
    else
      svc_healthy "$dep" || return 1
    fi
  done
  return 0
}

wait_healthy() {
  local svc="$1" i
  # 就绪断言轮询，不用固定 sleep 硬等；上限 90s
  for i in $(seq 1 45); do
    svc_healthy "$svc" && return 0
    sleep 2
  done
  return 1
}

boot_up() {
  echo "== 顺序启动（就绪断言，失败中止）=="
  for svc in "${ORDER[@]}"; do
    if ! dep_ready "$svc"; then
      echo "✗ ${DIAG[$svc]:-依赖未就绪: $svc}" >&2
      return 1
    fi
    echo "-> 起 $svc"
    $COMPOSE up -d --no-deps "$svc" 2>&1 | tail -2
    if ! wait_healthy "$svc"; then
      echo "✗ $svc 未通过就绪断言（90s）" >&2
      return 1
    fi
    echo "✓ $svc healthy"
  done
  echo "✓ 全栈 7 容器 healthy"
}

boot_up_single() {
  local svc="$1"
  local file="services/$svc/compose.yml"
  [[ -f "$file" ]] || { echo "✗ 无单服务编排: $file" >&2; return 1; }
  echo "-> 单服务启动 $svc（隔离端口，零依赖）"
  docker compose --env-file config/defaults.env -f "$file" up -d --no-deps --build "$svc" 2>&1 | tail -3
  if wait_healthy "$svc"; then echo "✓ $svc healthy（单起）"; else echo "✗ $svc 单起未健康" >&2; return 1; fi
}

boot_down_single() {
  local svc="$1"
  local file="services/$svc/compose.yml"
  [[ -f "$file" ]] || { echo "✗ 无单服务编排: $file" >&2; return 1; }
  docker compose --env-file config/defaults.env -f "$file" down
}

case "${1:-}" in
  up) boot_up ;;
  up-*) boot_up_single "${1#up-}" ;;
  down-*) boot_down_single "${1#down-}" ;;
  *) echo "用法: boot.sh up | up-<svc> | down-<svc>" >&2; exit 2 ;;
esac
