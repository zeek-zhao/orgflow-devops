#!/usr/bin/env bash
# backup-watchdog.sh —— 备份守护的轻量看护（M3.0.1 T1 沙箱兜底，与 quota-watchdog 同机制）
#
# 背景：真机 PID1=supervisord 用 [program:orgflow-backup] autorestart 原生拉起；
# 本沙箱云 IDE supervisord 对动态加入的 program 实测 autorestart 不触发（kill 后不拉起），
# 故加本 watchdog 作等价兜底：每 10s 检查 /run/orgflow-backup.pid 进程是否存活且
# 命令行匹配 backup-daemon.sh，死了就 nohup 拉起。watchdog 自身由 supervisor 托管或 nohup 常驻。
#
# 单实例：拉起前用 /proc 精确计数 backup-daemon.sh 主进程，>0 就不拉起（避免 supervisor
# 重启间隙 pidfile 失效导致双实例）。watchdog 只拉起，不执行备份，不与 daemon 双写状态。
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PIDFILE="${BACKUP_PIDFILE:-/run/orgflow-backup.pid}"
LOG="${BACKUP_LOG:-/var/log/orgflow/backup.log}"
CHECK_INTERVAL="${WATCHDOG_INTERVAL:-10}"

count_instances() {
  python3 - 2>/dev/null <<'PY' || echo 0
import os, glob
n=0
for d in glob.glob('/proc/[0-9]*/cmdline'):
    try:
        argv=[a.decode(errors='replace') for a in open(d,'rb').read().split(b'\0') if a]
    except Exception:
        continue
    # 精确匹配 [bash, <path>/backup-daemon.sh, run]，排除 watchdog 自身与命令替换子 shell
    if len(argv)>=2 and os.path.basename(argv[0])=='bash' and argv[1].endswith('/scripts/backup-daemon.sh'):
        n+=1
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
  [ -r "/proc/$pid/cmdline" ] || return 1
  tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | grep -q 'backup-daemon.sh' || return 1
}

while true; do
  if ! alive; then
    inst="$(count_instances)"
    if [ "$inst" -gt 0 ]; then
      echo "[watchdog] $(date -u '+%H:%M:%SZ') 检测到 $inst 个 daemon 实例，跳过拉起（pidfile 失效但已有实例在跑）" >> "$LOG"
    else
      old="$(cat "$PIDFILE" 2>/dev/null | tr -d '\r\n')"
      echo "[watchdog] $(date -u '+%H:%M:%SZ') 检测到 daemon 不在（pid=${old:-none}），拉起新进程" >> "$LOG"
      rm -f "$PIDFILE"
      cd "$ROOT"
      nohup bash "$ROOT/scripts/backup-daemon.sh" run >> "$LOG" 2>&1 &
      sleep 3
    fi
  fi
  sleep "$CHECK_INTERVAL"
done
