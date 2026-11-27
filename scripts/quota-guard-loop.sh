#!/usr/bin/env bash
# quota-guard-loop.sh —— 配额证据刷新循环（M2.5.3 P0-1 / P1-2）
#
# 三种宿主进程管理器（systemd-timer / supervisor / runit）与 cron/nohup 兜底统一调用本脚本，
# 避免刷新命令散落在 Makefile 里。职责：
#   1) 每 300s（QUOTA_INTERVAL 可覆盖）刷新一次 quota-guard 证据；
#   2) 写日志前先判大小：cron.log >1MB 即 mv 为 cron.log.1（保留 1 份），不依赖 logrotate 命令；
#   3) 每次刷新后写 artifacts/quota/alive.json（宿主侧自证存活：pid + ps 命令行 + mechanism +
#      ts + 日志最后写入时间），供 verify-quota-refresh Job 只读消费（agent 无 docker.sock、
#      无法跨 PID namespace 看宿主进程）。
#
# mechanism 来源优先级：环境变量 QUOTA_MECHANISM > artifacts/quota/mechanism.txt > nohup。
# 安装目标（quota-supervisor-install / quota-runit-install / quota-cron-install）写 mechanism.txt。
#
# 用法：
#   bash scripts/quota-guard-loop.sh                # 常驻循环（supervisor/runit/nohup）
#   bash scripts/quota-guard-loop.sh --once         # 单次刷新（cron 用，stdout 交调用方重定向）
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/artifacts/quota"
LOG="$OUT/cron.log"
CONTAINER="${QUOTA_CONTAINER:-of-builder}"
INTERVAL="${QUOTA_INTERVAL:-300}"
MECH="${QUOTA_MECHANISM:-}"
mkdir -p "$OUT"

[[ -n "$MECH" && -f "$OUT/mechanism.txt" ]] || [[ -n "$MECH" ]] || \
  { [ -f "$OUT/mechanism.txt" ] && MECH="$(cat "$OUT/mechanism.txt" 2>/dev/null | tr -d '\r\n')"; }
[[ -n "$MECH" ]] || MECH="nohup"

# P1-2：写日志前判断大小（>1MB 切分，保留 1 份）；真机也可选 logrotate（deploy/logrotate/orgflow-quota）。
rotate_log() {
  [ -f "$LOG" ] || return 0
  local sz
  sz="$(stat -c%s "$LOG" 2>/dev/null || echo 0)"
  if [ "$sz" -gt 1048576 ]; then
    mv -f "$LOG" "$LOG.1" 2>/dev/null || true
    : > "$LOG"
  fi
}

# 宿主侧自证：ps -p $$ -o args= 比对命令行含 quota-guard-loop.sh，避免只 kill -0 的 PID 复用误判。
write_alive() {
  local ts pid args alive logts esc
  ts="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  pid="$$"
  args="$(ps -p "$pid" -o args= 2>/dev/null | tr -d '\n' | tr -d '\r')"
  alive=false
  printf '%s' "$args" | grep -q 'quota-guard-loop.sh' && alive=true
  logts=""
  [ -f "$LOG" ] && logts="$(date -u -r "$LOG" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null)"
  esc="$(printf '%s' "$args" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')"
  printf '{"ts":"%s","pid":%s,"args":"%s","alive":%s,"mechanism":"%s","log_last_ts":"%s"}\n' \
    "$ts" "$pid" "$esc" "$alive" "$MECH" "$logts" > "$OUT/alive.json"
}

do_guard() { bash "$ROOT/scripts/quota-guard.sh" --container "$CONTAINER" --out "$OUT"; }

refresh_loop() {
  rotate_log
  do_guard >> "$LOG" 2>&1
  write_alive
}

refresh_once() {
  rotate_log
  do_guard
  write_alive
}

case "${1:-}" in
  --once)  refresh_once; exit $? ;;
  -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
  "") ;;
  *) echo "[quota-loop] ✗ 未知参数: $1" >&2; exit 3 ;;
esac

echo "[quota-loop] 启动：mechanism=$MECH interval=${INTERVAL}s container=$CONTAINER log=$LOG"
# 常驻模式写 daemon.pid（自报 PID）；supervisor/runit/nohup 统一据此判活，
# 重启后新进程会覆盖旧 PID。--once 模式（cron）不写 pidfile。
echo "$$" > "$OUT/daemon.pid"
trap 'rm -f "$OUT/daemon.pid"' EXIT INT TERM
while true; do
  refresh_loop
  sleep "$INTERVAL"
done
