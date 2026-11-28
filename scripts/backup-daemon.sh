#!/usr/bin/env bash
# backup-daemon.sh —— M3.0.1 T1 备份守护常驻进程（备份从"人跑"变成"守护跑"）
#
# 职责（与 quota-guard-loop.sh 同机制，PID1=supervisord）：
#   1) 常驻循环：计算下一个本地时间 03:30 执行 scripts/backup.sh；
#   2) 启动补跑：若 /data/backups/latest 对应备份超过 26 小时，立即补跑一次再进入等待；
#   3) 单实例：/run/orgflow-backup.pid + flock，pidfile 指向存活进程则 exit 4；
#   4) 状态文件 /data/backups/status.json（last_start/last_end/exit_code/duration_sec/
#      bytes/volumes/commit/retention{daily,weekly}/next_run/disk_used_pct/verify）；
#   5) 保留轮转：日备 7 份、周备（weekly.flag）4 份；只删 YYYYMMDDTHHMMSSZ 命名目录，
#      不删 latest 指向、不删周备保留集；删除前先打印 dry-run 列表；
#   6) 水位保护：/data 使用率 > 阈值（默认 85%）时跳过本轮并写 exit_code=5。
#
# 关键设计（避免与 supervisor autorestart 打架）：
#   - 单实例冲突 exit 4 只在"另一个存活实例已在跑"时发生；此时 supervisor 拉起的新进程
#     若因 pidfile 指向自身（旧 pid 已死）而继续，不会反复重启。kill -9 后 pidfile 残留
#     旧 pid，new process 通过 /proc/<pid> 精确校验确认已死后接管。
#   - BACKUP_FAKE_NOW=<epoch|'YYYY-MM-DD HH:MM:SS'> 仅用于测试注入"当前时间"，
#     驱动补跑判定与轮转的 weekly 判定，不读系统时钟以外的生产数据。
#   - BACKUP_DRY_RUN=1 只打印将删除列表，不执行删除（保留策略 dry-run）。
#   - 水位阈值可用 BACKUP_WATERMARK=NN 覆盖（验收 4 注入低于当前水位的值）。
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT="${BACKUP_ROOT:-/data/backups}"
PIDFILE="${BACKUP_PIDFILE:-/run/orgflow-backup.pid}"
LOCKFILE="${BACKUP_LOCKFILE:-/run/orgflow-backup.lock}"
STATUS="$ROOT/status.json"
INTERVAL_H="${BACKUP_INTERVAL_H:-26}"
WATERMARK="${BACKUP_WATERMARK:-85}"
LOG="${BACKUP_LOG:-/var/log/orgflow/backup.log}"

mkdir -p "$ROOT" "$(dirname "$LOG")" "$(dirname "$PIDFILE")"

# 日志只写 stdout：supervisor 的 stdout_logfile 会落盘到 /var/log/orgflow/backup.log；
# 手动运行（once）则由调用方重定向。切勿再用 tee 写同一文件，否则双行。
log() { printf '%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*"; }

now_epoch() {
  if [ -n "${BACKUP_FAKE_NOW:-}" ]; then
    date -d "$BACKUP_FAKE_NOW" +%s 2>/dev/null || echo "$BACKUP_FAKE_NOW"
  else
    date +%s
  fi
}

disk_used_pct() {
  # /data 未必是独立挂载点；取其所在文件系统的用量百分比（去 %）。
  df -P "$ROOT" 2>/dev/null | awk 'NR==2{gsub(/%/,"",$5);print $5+0}'
}

# 精确判断 pid 是否为存活的 backup-daemon 进程（避免 PID 复用误判）
pid_is_live_daemon() {
  local p="$1"
  [ -n "$p" ] || return 1
  kill -0 "$p" 2>/dev/null || return 1
  [ -r "/proc/$p/cmdline" ] || return 1
  tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null | grep -q 'backup-daemon.sh'
}

acquire_single_instance() {
  if [ -f "$PIDFILE" ]; then
    local oldpid; oldpid="$(cat "$PIDFILE" 2>/dev/null || true)"
    # 旧 pid 是自身（supervisor 重启后 PID 复用）或已死 → 可接管；存活的另一实例 → exit 4
    if [ -n "$oldpid" ] && [ "$oldpid" != "$$" ] && pid_is_live_daemon "$oldpid"; then
      log "✗ 已有存活 backup-daemon 实例 pid=$oldpid，exit 4（单实例保护）"
      exit 4
    fi
  fi
  # flock 兜底：即使 pidfile 竞态，也只有一个进程持有锁
  exec 9>"$LOCKFILE"
  if ! flock -n 9; then
    log "✗ flock 竞争失败（另一实例持锁），exit 4"
    exit 4
  fi
  echo "$$" > "$PIDFILE"
  local mypid; mypid="$(cat "$PIDFILE")"
  # trap 只删自己的 pidfile（防止误删新实例）
  cleanup() {
    [ "$(cat "$PIDFILE" 2>/dev/null || true)" = "$mypid" ] && rm -f "$PIDFILE"
  }
  trap cleanup EXIT INT TERM
  log "✓ 取得单实例锁 pid=$$ pidfile=$PIDFILE"
}

# 写状态文件（原子替换）；用 python 保证 JSON 合法。
write_status() {
  local last_start="$1" last_end="$2" exit_code="$3" duration="$4" bytes="$5" \
        volumes="$6" commit="$7" next_run="$8" diskpct="$9" verify="${10:-}"
  python3 - "$STATUS" "$last_start" "$last_end" "$exit_code" "$duration" "$bytes" \
      "$volumes" "$commit" "$next_run" "$diskpct" "$verify" <<'PY'
import json, sys, os, tempfile
p=sys.argv[1]
last_start,last_end,code,duration,bytes_,volumes,commit,next_run,diskpct,verify=sys.argv[2:]
try:
    old=json.load(open(p,encoding='utf-8'))
except Exception:
    old={}
d={
  "last_start": last_start,
  "last_end": last_end,
  "exit_code": int(code) if code.isdigit() else code,
  "duration_sec": int(float(duration)) if duration else 0,
  "bytes": int(bytes_) if bytes_.isdigit() else 0,
  "volumes": int(volumes) if volumes.isdigit() else 0,
  "commit": commit,
  "retention": {"daily": 7, "weekly": 4},
  "next_run": next_run,
  "disk_used_pct": int(float(diskpct)) if diskpct else 0,
}
if verify:
    try: d["verify"]=json.loads(verify)
    except Exception: d["verify"]={"ok": False, "failures": ["unparsable"]}
d["updated_at"]=last_end
tmp=p+".tmp"
json.dump(d,open(tmp,'w',encoding='utf-8'),ensure_ascii=False,indent=2)
os.replace(tmp,p)
PY
}

# ---- 保留轮转：日备 7 / 周备（weekly.flag）4 ----
# 只处理匹配 ^[0-9]{8}T[0-9]{6}Z$ 的目录；保护 latest 指向与周备保留集。
rotate() {
  local dry="$1" now="$2"
  python3 - "$ROOT" "$dry" "$now" <<'PY'
import os, sys, re, datetime
root, dry, now = sys.argv[1], sys.argv[2], sys.argv[3]
pat=re.compile(r'^\d{8}T\d{6}Z$')
try:
    cur=datetime.datetime.strptime(now,'%Y%m%dT%H%M%SZ')
except ValueError:
    cur=datetime.datetime.strptime(now,'%Y-%m-%d %H:%M:%S')
try: latest=open(os.path.join(root,'latest')).read().strip()
except Exception: latest=''
latest_name=os.path.basename(latest)

def ts_of(name):
    return datetime.datetime.strptime(name,'%Y%m%dT%H%M%SZ')

days=[]; weeks=[]
for n in os.listdir(root):
    p=os.path.join(root,n)
    if not os.path.isdir(p) or not pat.match(n): continue
    weekly=os.path.exists(os.path.join(p,'weekly.flag'))
    (weeks if weekly else days).append((ts_of(n),n))

def protected(n):
    # 永不删 latest 指向；周备保留集由 plan 的 keep 保证。
    return n==latest_name

def plan(items, keep, protect_latest=True):
    """按时间从旧到新，保留最近 keep 份（含 latest 若在其中），返回可删列表。"""
    items=sorted(items)
    if len(items)<=keep: return []
    cand=items[:len(items)-keep]
    if protect_latest:
        cand=[x for x in cand if not (x[1]==latest_name)]
    return cand

# 日备：非 weekly.flag 目录，保留最近 7 份；周备：weekly.flag 目录，保留最近 4 份。
# latest 指向目录若属日备，计入 7 份配额（plan 天然按时间排序保留，latest 通常最新故不会进 cand）。
del_days=plan(days,7)
del_weeks=plan(weeks,4)
keep_days=len(days)-len(del_days)
keep_weeks=len(weeks)-len(del_weeks)
print("[rotate] dry_run=%s daily_keep=%d(del=%d) weekly_keep=%d(del=%d) latest=%s" % (
    dry, keep_days, len(del_days), keep_weeks, len(del_weeks), latest_name))
for d,n in del_days: print("  [rotate] DELETE daily %s" % n)
for d,n in del_weeks: print("  [rotate] DELETE weekly %s" % n)
if dry=='0':
    for d,n in del_days+del_weeks:
        import shutil
        shutil.rmtree(os.path.join(root,n),ignore_errors=True)
        print("  [rotate] removed %s" % n)
PY
}

# ---- 执行一轮备份（供补跑与 03:30 定时调用）----
run_once() {
  local diskpct; diskpct="$(disk_used_pct)"
  local start_epoch; start_epoch="$(now_epoch)"
  local start; start="$(date -u -d "@$start_epoch" '+%Y-%m-%dT%H:%M:%SZ')"

  # 水位保护
  if [ "$diskpct" -gt "$WATERMARK" ]; then
    log "✗ 磁盘水位保护：$diskpct% > ${WATERMARK}%，本轮跳过（exit_code=5）"
    local end; end="$(date -u -d "@$start_epoch" '+%Y-%m-%dT%H:%M:%SZ')"
    write_status "$start" "$end" 5 0 0 0 "$(git -C "$REPO" rev-parse HEAD 2>/dev/null || echo unknown)" "" "$diskpct" ""
    return 5
  fi

  log "[backup] 触发一轮备份（disk=${diskpct}% watermark=${WATERMARK}%）"
  local rc=0
  BACKUP_ROOT="$ROOT" bash "$REPO/scripts/backup.sh" "$ROOT" 2>&1 || rc=$?
  local end_epoch; end_epoch="$(now_epoch)"
  local end; end="$(date -u -d "@$end_epoch" '+%Y-%m-%dT%H:%M:%SZ')"
  local dur=$(( end_epoch - start_epoch ))

  # 收集状态：latest 指向目录的 manifest
  local dest bytes=0 volumes=0 commit=""
  dest="$(cat "$ROOT/latest" 2>/dev/null || true)"
  commit="$(git -C "$REPO" rev-parse HEAD 2>/dev/null || echo unknown)"
  if [ -n "$dest" ] && [ -f "$dest/manifest.json" ]; then
    eval "$(python3 - "$dest/manifest.json" <<'PY'
import json,sys,os
m=json.load(open(sys.argv[1],encoding='utf-8'))
tot=sum(os.path.getsize(os.path.join(os.path.dirname(sys.argv[1]),e['archive'])) for e in m['volumes'])
print("bytes=%d volumes=%d" % (tot, m.get('total_volumes',len(m['volumes']))))
PY
)" 2>/dev/null || true
  fi

  # 周日备份打 weekly.flag（用备份目录名里的 UTC 日期判定，而非当前时间）
  if [ -n "$dest" ]; then
    local dname; dname="$(basename "$dest")"
    local dow; dow="$(date -u -d "$(python3 -c "import sys,datetime;print(datetime.datetime.strptime(sys.argv[1],'%Y%m%dT%H%M%SZ').strftime('%Y-%m-%d'))" "$dname" 2>/dev/null)" +%u 2>/dev/null || echo 0)"
    if [ "$dow" = "7" ]; then
      : > "$dest/weekly.flag"
      log "[backup] 周日备份：写入 weekly.flag ($dname)"
    fi
  fi

  local dry=0; [ "${BACKUP_DRY_RUN:-0}" = "1" ] && dry=1
  local dname_now; dname_now="$(date -u -d "@$end_epoch" '+%Y%m%dT%H%M%SZ')"
  rotate "$dry" "$dname_now" || true

  # 下一次运行时间（本地 03:30）
  local nextrun; nextrun="$(next_0330 "$end_epoch")"
  write_status "$start" "$end" "$rc" "$dur" "$bytes" "$volumes" "$commit" "$nextrun" "$diskpct" ""

  # T5：备份成功后自动跑一致性校验，verify 字段写入 status.json（在 write_status 之后，不被覆盖）。
  if [ "$rc" -eq 0 ]; then
    bash "$REPO/scripts/backup-verify.sh" "$dest" 2>&1 || true
  fi

  if [ "$rc" -eq 0 ]; then
    log "✓ 一轮备份完成 rc=0 dest=$dest bytes=$bytes volumes=$volumes next_run=$nextrun"
  else
    log "✗ 一轮备份失败 rc=$rc（保留现场 $dest）"
  fi
  return "$rc"
}

# 计算下一个本地 03:30（从 from_epoch 之后），输出 ISO8601 字符串
next_0330() {
  local from="${1:-$(date +%s)}"
  python3 - "$from" <<'PY'
import sys, datetime
t=datetime.datetime.fromtimestamp(int(sys.argv[1]))
target=t.replace(hour=3,minute=30,second=0,microsecond=0)
if target<=t: target+=datetime.timedelta(days=1)
print(target.strftime('%Y-%m-%dT%H:%M:%S%z'))
PY
}

# 补跑判定：latest 对应备份 age（小时）> INTERVAL_H 则立即跑一次
maybe_catchup() {
  local latest; latest="$(cat "$ROOT/latest" 2>/dev/null || true)"
  local need=0
  if [ -z "$latest" ] || [ ! -d "$latest" ]; then
    need=1
    log "[catchup] 无 latest 指向，立即补跑"
  else
    local dname; dname="$(basename "$latest")"
    local ets; ets="$(date -u -d "$(python3 -c "import sys,datetime;print(datetime.datetime.strptime(sys.argv[1],'%Y%m%dT%H%M%SZ').strftime('%Y-%m-%d %H:%M:%S'))" "$dname" 2>/dev/null)" +%s 2>/dev/null || echo 0)"
    local age_h=$(( ( $(now_epoch) - ets ) / 3600 ))
    log "[catchup] latest=$dname age=${age_h}h threshold=${INTERVAL_H}h"
    [ "$age_h" -gt "$INTERVAL_H" ] && need=1
  fi
  [ "$need" = "1" ] && run_once || true
}

usage() {
  cat <<EOF
用法: bash scripts/backup-daemon.sh [run|once|rotate|status]
  run     常驻循环（默认）：补跑判定 + 每本地 03:30 备份（supervisor 管理）
  once    执行一轮备份+状态+轮转后退出（供补跑/测试，支持 BACKUP_FAKE_NOW）
  simulate 轻量模拟一轮（造目录+轮转，配 BACKUP_FAKE_NOW 注入连续日期测保留策略）
  rotate  仅执行保留轮转（BACKUP_DRY_RUN=1 打印 dry-run）
  status  打印 status.json
环境变量：BACKUP_ROOT BACKUP_PIDFILE BACKUP_FAKE_NOW BACKUP_WATERMARK
         BACKUP_DRY_RUN BACKUP_INTERVAL_H BACKUP_LOG
EOF
}

main() {
  local cmd="${1:-run}"
  case "$cmd" in
    once)
      run_once
      ;;
    rotate)
      local dry=0; [ "${BACKUP_DRY_RUN:-0}" = "1" ] && dry=1
      rotate "$dry" "$(date -u -d "@$(now_epoch)" '+%Y%m%dT%H%M%SZ')"
      ;;
    simulate)
      # 轻量模拟一轮：用 BACKUP_FAKE_NOW 对应的日期造一个备份目录（不真实打包），
      # 写 latest + weekly.flag（周日）后执行轮转。供验收 2/3 注入连续日期快速复现。
      local fake="${BACKUP_FAKE_NOW:-}"
      [ -n "$fake" ] || { echo "✗ simulate 需 BACKUP_FAKE_NOW" >&2; exit 2; }
      local ts; ts="$(python3 - "$fake" <<'PY'
import sys,datetime
s=sys.argv[1]
try:
    d=datetime.datetime.strptime(s,'%Y%m%dT%H%M%SZ')
except ValueError:
    d=datetime.datetime.strptime(s,'%Y-%m-%d %H:%M:%S')
print(d.strftime('%Y%m%dT%H%M%SZ'))
PY
)" || exit 2
      local dest="$ROOT/$ts"; mkdir -p "$dest"
      printf '{"total_volumes":9,"volumes":[],"simulated":true}' > "$dest/manifest.json"
      if [ "${DISABLE_WEEKLY:-0}" != "1" ] && [ "$(date -u -d "$(python3 -c "import sys,datetime;print(datetime.datetime.strptime(sys.argv[1],'%Y%m%dT%H%M%SZ').strftime('%Y-%m-%d'))" "$ts")" +%u 2>/dev/null)" = "7" ]; then
        : > "$dest/weekly.flag"
      fi
      printf '%s' "$dest" > "$ROOT/latest"
      log "[simulate] 造备份目录 $dest（fake_now=$fake）"
      rotate 0 "$ts"
      ;;
    status)
      cat "$STATUS" 2>/dev/null || { echo "无 $STATUS"; exit 1; }
      ;;
    run)
      acquire_single_instance
      log "=== backup-daemon 启动 pid=$$ root=$ROOT interval=${INTERVAL_H}h watermark=${WATERMARK}% ==="
      maybe_catchup
      while true; do
        local target_epoch; target_epoch="$(date -d "$(next_0330 "$(date +%s)")" +%s 2>/dev/null || echo 0)"
        local now; now="$(date +%s)"
        local wait=$(( target_epoch - now ))
        [ "$wait" -lt 1 ] && wait=1
        log "[sleep] 下一次 03:30 于 $(date -d "@$target_epoch" '+%F %T %z')（${wait}s 后）"
        # 分段 sleep，便于 supervisor stop 快速响应；最长 60s 一段
        local slept=0
        while [ "$slept" -lt "$wait" ]; do
          local chunk=$(( wait - slept )); [ "$chunk" -gt 60 ] && chunk=60
          # 关键：sleep 子进程关闭 fd 9（锁 fd），否则 kill -9 主进程后 sleep 继承锁不放，
          # watchdog 拉起的新进程 flock 竞争失败 exit 4（自愈失效）。
          sleep "$chunk" 9>&-; slept=$(( slept + chunk ))
        done
        run_once || log "⚠ 本轮备份失败 rc=$?，守护继续等待下一轮（现场保留）"
      done
      ;;
    -h|--help|help)
      usage ;;
    *)
      usage; exit 2 ;;
  esac
}

main "$@"
