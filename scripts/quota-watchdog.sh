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
#
# m2.5.4 P0-1：拉起前做一次"全局实例数"判断（pgrep -fc '[q]uota-guard-loop.sh'），
# 只要宿主上已有任意 loop 在跑就不拉起——比只看 pidfile 可靠，能兜住 supervisor
# "杀旧进程到起新进程"的间隙（旧进程晚退出会删掉新 pidfile，watchdog 误判无主再拉一个）。
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PIDFILE="$ROOT/artifacts/quota/daemon.pid"
LOG="$ROOT/artifacts/quota/supervisor.log"
CHECK_INTERVAL="${WATCHDOG_INTERVAL:-10}"
# 精确锚定 loop 主进程：逐 /proc/PID/cmdline 比对参数数组 [bash, <abs>/scripts/quota-guard-loop.sh]，
# 等价 pgrep -fc '[q]uota-guard-loop.sh' 但排除 nohup/setsid wrapper 与 grep 自身的瞬时假阳性。
count_instances() {
  # watchdog 自身 cmdline（quota-watchdog.sh）与其命令替换子 shell 都不含 loop.sh，
  # 无需按 PPID 过滤（loop 本身是 watchdog 子进程，过滤 PPID 会漏掉真 loop）。
  python3 - 2>/dev/null <<'PY' || echo 0
import os, glob
n = 0
for d in glob.glob('/proc/[0-9]*/cmdline'):
    try:
        argv = [a.decode(errors='replace') for a in open(d, 'rb').read().split(b'\0') if a]
    except Exception:
        continue
    if len(argv) == 2 and os.path.basename(argv[0]) == 'bash' and (argv[1].endswith('/scripts/quota-guard-loop.sh') or argv[1] == 'scripts/quota-guard-loop.sh' or argv[1].endswith('/quota-guard-loop.sh') and '/scripts/' in argv[1]):
        n += 1
print(n)
PY
}

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
    # 全局实例数兜底：即使 pidfile 失效（被旧 loop trap 误删 / supervisor 重启间隙），
    # 只要已有 loop 在跑就不拉起，避免双实例写同一份证据。
    inst="$(count_instances)"
    if [ "$inst" -gt 0 ]; then
      echo "[watchdog] $(date -u '+%H:%M:%SZ') 检测到 $inst 个实例，跳过拉起（pidfile 失效但已有 loop 在跑）" >> "$LOG"
    else
      old="$(cat "$PIDFILE" 2>/dev/null | tr -d '\r\n')"
      echo "[watchdog] $(date -u '+%H:%M:%SZ') 检测到 loop 不在（pid=${old:-none}），拉起新进程" >> "$LOG"
      rm -f "$PIDFILE"
      nohup bash "$ROOT/scripts/quota-guard-loop.sh" >> "$LOG" 2>&1 &
      sleep 3
    fi
  fi
  sleep "$CHECK_INTERVAL"
done
