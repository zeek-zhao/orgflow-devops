#!/usr/bin/env bash
# 30-up-serial.sh —— 按 config/services.yml 的 start_order 串行启动整栈。
#
# 为什么串行而不是一把 up：M0 的依赖是**健康依赖**而不是启动顺序依赖。
# 一把 up 时 compose 只保证容器「创建顺序」，dnsmasq 还没就绪，别的容器就开始
# 解析域名，表现是随机的连接失败；dex 还没就绪，oauth2-proxy 就拉 jwks。
# 串行 + 每个服务等到 healthy 再起下一个，失败点**唯一确定**。
#
# 用法：
#   bash scripts/30-up-serial.sh            # 整栈
#   bash scripts/30-up-serial.sh jenkins    # 单个服务（带依赖）
# 环境：
#   USE_GHCR=1     拉 GHCR 上按 digest 锁定的镜像，不本地构建（213 一律用这个）
#   HEALTH_TIMEOUT 单个服务等待健康的超时秒数（默认按 config/services.yml 的 health_wait）
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
# shellcheck source=lib/runtime.sh
. "$ROOT/scripts/lib/runtime.sh"

RUNTIME_ENV="$(orgflow_runtime_env)"
[ -f "$RUNTIME_ENV" ] || orgflow_fail "缺少 $RUNTIME_ENV；先跑 bash scripts/10-render-config.sh（make render）"

COMPOSE=(docker compose --env-file "$RUNTIME_ENV" -f docker-compose.yml)
if [ "${USE_GHCR:-0}" = 1 ]; then
  COMPOSE+=(-f docker-compose.ghcr.yml)
  BUILD_FLAG="--no-build"
else
  BUILD_FLAG="--build"
fi

target="${1:-}"
if [ -n "$target" ]; then
  order="$target"
else
  mapfile -t order < <(orgflow_start_order)
fi

orgflow_export_runtime_env

# ★ certs-init 是一次性容器（restart:no），负责把站点叶子证书签进 ca_sites 卷；
#   它不在 config/services.yml 的 start_order 里（那个列表只含常驻业务服务），
#   而 caddy 的 depends_on 条件是 service_completed_successfully —— 串行用 --no-deps
#   起 caddy 时这条依赖被绕过，若 certs-init 没先跑，caddy 挂空卷会因缺
#   /certs/sites/<sub>.<domain>.crt 无限重启。整栈模式必须先幂等跑一次 certs-init。
#   （CI harness 用 compose up 一把起，depends_on 生效，所以这里从未被覆盖。）
if [ -z "$target" ]; then
  echo "-- [certs-init] 幂等签发叶子证书到 ca_sites 卷"
  "${COMPOSE[@]}" run --rm certs-init >/dev/null 2>&1 ||     orgflow_fail "certs-init 签发叶子证书失败；检查 secrets/ca/ 与 config/routes.yaml"
fi

echo "== 串行启动（$([ -n "$target" ] && echo "单服务 $target" || echo "${#order[@]} 个服务")）=="
for svc in "${order[@]}"; do
  up_log="$(mktemp)"
  trap 'rm -f "$up_log"' EXIT
  wait_for="$(orgflow_service_field "$svc" health_wait 2>/dev/null || true)"
  wait_for="${HEALTH_TIMEOUT:-${wait_for:-120}}"
  echo "-- [$svc] up（健康超时 ${wait_for}s）"
  # ★ 不能写成 `if ! compose up ... | orgflow_redact`：管道退出码是 redact 的，
  #   docker 的 23/125 会被吞成 1，真机上被误读成「参数写错」。先落盘再脱敏输出。
  "${COMPOSE[@]}" up -d --no-deps "$BUILD_FLAG" --quiet-pull "$svc" >"$up_log" 2>&1 && up_rc=0 || up_rc=$?
  if [ "$up_rc" -ne 0 ]; then
    orgflow_redact <"$up_log" >&2
    orgflow_diagnose "$svc"
    echo "$svc 启动失败（拉取/构建阶段），compose 退出码 $up_rc" >&2
    exit "$up_rc"
  fi
  orgflow_redact <"$up_log"
  if ! orgflow_wait_healthy "$svc" "$wait_for"; then
    orgflow_diagnose "$svc"
    orgflow_fail "$svc 未在 ${wait_for}s 内变成 healthy"
  fi
  echo "   ✓ $svc healthy"
done

echo "== 全部服务 healthy =="
"${COMPOSE[@]}" ps
