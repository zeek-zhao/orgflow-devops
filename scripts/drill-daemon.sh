#!/usr/bin/env bash
# drill-daemon.sh —— M3.0.2 T4 隔离恢复演练守护常驻进程
#
# 职责（与 backup-daemon.sh / quota-guard-loop.sh 同机制）：
#   1) 常驻循环：计算下一个本地（Asia/Shanghai）周日 04:00 执行 scripts/drill-up.sh；
#   2) 启动补跑：若 /data/drill/drill.result 的 ts 超过 26 小时未更新，立即补跑一次；
#   3) 单实例：/run/orgflow-drill.pid + flock，pidfile 指向存活进程则 exit 4；
#   4) 日志只写 stdout（supervisor stdout_logfile 落盘）；sleep 关闭锁 fd 防孤儿持有。
#
# 环境变量：
#   DRILL_PIDFILE  默认 /run/orgflow-drill.pid
#   DRILL_LOCKFILE 默认 /run/orgflow-drill.lock
#   DRILL_INTERVAL_H 默认 26（补跑阈值）
#   DRILL_LOG 默认 /var/log/orgflow/drill.log
#   DRILL_FAKE_NOW 仅测试注入当前时间（epoch 或 'YYYY-MM-DD HH:MM:SS'）
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"
PIDFILE="${DRILL_PIDFILE:-/run/orgflow-drill.pid}"
LOCKFILE="${DRILL_LOCKFILE:-/run/orgflow-drill.lock}"
INTERVAL_H="${DRILL_INTERVAL_H:-26}"
LOG="${DRILL_LOG:-/var/log/orgflow/drill.log}"
RESULT="/data/drill/drill.result"
mkdir -p "$(dirname "$LOG")" "$(dirname "$PIDFILE")" "$(dirname "$RESULT")"

log() { printf '%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*"; }

now_epoch() {
  if [ -n "${DRILL_FAKE_NOW:-}" ]; then
    date -d "$DRILL_FAKE_NOW" +%s 2>/dev/null || echo "$DRILL_FAKE_NOW"
  else
    date +%s
  fi
}

pid_is_live_daemon() {
  local p="$1"
  [ -n "$p" ] || return 1
  kill -0 "$p" 2>/dev/null || return 1
  [ -r "/proc/$p/cmdline" ] || return 1
  tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null | grep -q 'drill-daemon.sh'
}

acquire_single_instance() {
  if [ -f "$PIDFILE" ]; then
    local oldpid; oldpid="$(cat "$PIDFILE" 2>/dev/null || true)"
    if [ -n "$oldpid" ] && [ "$oldpid" != "$$" ] && pid_is_live_daemon "$oldpid"; then
      log "✗ 已有存活 drill-daemon 实例 pid=$oldpid，exit 4（单实例保护）"
      exit 4
    fi
  fi
  exec 9>"$LOCKFILE"
  if ! flock -n 9; then
    log "✗ flock 竞争失败（另一实例持锁），exit 4"
    exit 4
  fi
  echo "$$" > "$PIDFILE"
  local mypid; mypid="$(cat "$PIDFILE")"
  cleanup() { [ "$(cat "$PIDFILE" 2>/dev/null || true)" = "$mypid" ] && rm -f "$PIDFILE"; }
  trap cleanup EXIT INT TERM
  log "✓ 取得单实例锁 pid=$$ pidfile=$PIDFILE"
}

# 计算下一个本地周日 04:00（Asia/Shanghai），返回 epoch
next_sunday_0400() {
  local from="$1"
  python3 - "$from" <<'PY'
import sys
from datetime import datetime, timedelta, timezone
t=datetime.fromtimestamp(int(sys.argv[1]), tz=timezone(timedelta(hours=8)))
# weekday(): Mon=0..Sun=6；目标周日=6
days=(6 - t.weekday()) % 7
if days==0 and (t.hour>4 or (t.hour==4 and t.minute>=0)):
    days=7
d=(t + timedelta(days=days)).replace(hour=4,minute=0,second=0,microsecond=0)
print(int(d.timestamp()))
PY
}

# 读 drill.result 的 ts（日志目录名 YYYYMMDDTHHMMSSZ），算 age 小时；无法解析返回巨大值触发补跑
result_age_h() {
  python3 - "$RESULT" <<'PY' 2>/dev/null
import sys,json,datetime
try:
    d=json.load(open(sys.argv[1],encoding='utf-8'))
    ts=d.get('ts','')
    t=datetime.datetime.strptime(ts,'%Y%m%dT%H%M%SZ')
    print(int((datetime.datetime.utcnow()-t).total_seconds()/3600))
except Exception:
    print(99999)
PY
}

run_drill() {
  log "[drill] 触发隔离恢复演练 drill-up.sh"
  local rc=0
  bash "$REPO/scripts/drill-up.sh" >>"$LOG" 2>&1 || rc=$?
  log "[drill] drill-up.sh 结束 rc=$rc"
  return "$rc"
}

maybe_catchup() {
  local age; age="$(result_age_h)"
  log "[catchup] drill.result age=${age}h threshold=${INTERVAL_H}h"
  [ "$age" -gt "$INTERVAL_H" ] && run_drill || true
}

# 分段 sleep：每 60s 醒一次，关闭锁 fd 9 防止孤儿 sleep 持有 flock
sleep_chunks() {
  local secs="$1" slept=0
  while [ "$slept" -lt "$secs" ]; do
    local chunk=$(( secs - slept )); [ "$chunk" -gt 60 ] && chunk=60
    sleep "$chunk" 9>&-
    slept=$(( slept + chunk ))
  done
}

main() {
  acquire_single_instance
  log "=== drill-daemon 启动 pid=$$ next_sunday_0400 ==="
  maybe_catchup
  while true; do
    local now; now="$(now_epoch)"
    local target; target="$(next_sunday_0400 "$now")"
    local wait=$(( target - now )); [ "$wait" -lt 1 ] && wait=1
    log "[drill] 下次本地周日 04:00 epoch=$target，等待 ${wait}s"
    sleep_chunks "$wait"
    run_drill || log "⚠ 本轮 drill 失败 rc=$?，守护继续等待下周日"
  done
}

main "$@"
