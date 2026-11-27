#!/usr/bin/env bash
# quota-watchdog.sh —— 刷新循环的轻量看护（m2.5.3 P0-1 沙箱兜底）
#
# 背景：真机 PID1=systemd 用 timer、PID1=supervisord 用 [program:orgflow-quota] autorestart、
# 其他 PID1 用 runit sv，均由宿主进程管理器原生拉起。本沙箱的云 IDE supervisord 对
# 动态加入的 program 实测 autorestart 不触发（kill 后不拉起），故加本 watchdog 作等价兜底：
# 每 10s 检查 daemon.pid 进程是否存活且命令行匹配 quota-guard-loop.sh，死了就拉起。
#
# watchdog 自身由 supervisord 托管（program:orgflow-quota-watchdog）或 nohup 常驻；
# 仅看护 loop，不承担刷新，不与 loop 双写证据（只有 loop 调 quota-guard.sh）。
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PIDFILE="$ROOT/artifacts/quota/daemon.pid"
LOG="$ROOT/artifacts/quota/supervisor.log"
CHECK_INTERVAL="${WATCHDOG_INTERVAL:-10}"

echo "[watchdog] 启动：看护 $PIDFILE，间隔 ${CHECK_INTERVAL}s，pid=$$" >> "$LOG"

alive() {
  local pid
  [ -f "$PIDFILE" ] || return 1
  pid="$(cat "$PIDFILE" 2>/dev/null | tr -d '\r\n')"
  [ -n "$pid" ] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  ps -p "$pid" -o args= 2>/dev/null | grep -qF 'quota-guard-loop.sh' || return 1
}

while true; do
  if ! alive; then
    old="$(cat "$PIDFILE" 2>/dev/null | tr -d '\r\n')"
    echo "[watchdog] $(date -u '+%H:%M:%SZ') 检测到 loop 不在（pid=${old:-none}），拉起新进程" >> "$LOG"
    rm -f "$PIDFILE"
    nohup bash "$ROOT/scripts/quota-guard-loop.sh" >> "$LOG" 2>&1 &
    sleep 3
  fi
  sleep "$CHECK_INTERVAL"
done
