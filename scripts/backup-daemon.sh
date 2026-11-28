#!/usr/bin/env bash
# backup-daemon.sh —— M3.0.3 备份运维工具（去 03:30 常驻，改手动 + up.sh 启动补跑）
#
# M3.0.3 T5（E2）：服务随时可能被关停，"睡到每天 03:30"不可靠且关停后永不补。
# 本脚本只保留 once/rotate/status/simulate 供手动调用；run 常驻模式已移除（调用报错退出）。
# up.sh 在全部服务 healthy 后同步检查 /data/backups/latest 年龄（>26h 或缺失则前台跑一次
# backup.sh），是一次性动作，不是定时器。
#
# 职责：
#   1) once：手动执行一轮备份（scripts/backup.sh）+ 状态 + 轮转；
#   2) rotate：保留轮转（日备 7 / 周备 weekly.flag 4）；
#   3) status：打印 /data/backups/status.json（last_start/last_end/exit_code/duration_sec/
#      bytes/volumes/commit/retention{daily,weekly}/next_run/disk_used_pct/verify）；
#   4) simulate：轻量模拟（配 BACKUP_FAKE_NOW 验保留策略）。
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

# D3（M3.0.2）：把 UTC 目录名时间戳转成 Asia/Shanghai 的本地日期与星期。
# 输出 "YYYY-MM-DD HH" 两字段（HH=1..7，7=周日）；Asia/Shanghai 无 DST，固定 UTC+8。
# 用 python 一次性算好，避免 date -u/+%u 混用导致的跨日错位。
local_day() {
  local dname="$1"
  python3 - "$dname" <<'PY' 2>/dev/null
import sys
from datetime import datetime, timedelta, timezone
d=datetime.strptime(sys.argv[1],'%Y%m%dT%H%M%SZ').replace(tzinfo=timezone.utc)
l=d.astimezone(timezone(timedelta(hours=8)))
print(l.strftime('%Y-%m-%d'), int(l.strftime('%u')))
PY
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
    wf=os.path.join(p,'weekly.flag')
    weekly=False
    if os.path.exists(wf):
        # D3（M3.0.2）：校验 marker 合法性——必须含 weekday=7、local_date、backup_ts。
        # 坏 marker（如手工写坏 weekday=0）不得当作周备，且保护其不被轮转删除（skip invalid marker）。
        try:
            kv=dict(line.strip().split('=',1) for line in open(wf,encoding='utf-8') if '=' in line)
        except Exception:
            kv={}
        valid=(kv.get('weekday')=='7' and bool(kv.get('local_date')) and bool(kv.get('backup_ts')))
        if valid:
            weekly=True
        else:
            print("[rotate] skip invalid marker %s（weekday=%s local_date=%s backup_ts=%s，不删不归类）" % (
                n, kv.get('weekday'), kv.get('local_date','-'), kv.get('backup_ts','-')))
            # 坏 marker 目录视为受保护，既不进 days 也不进 weeks，避免被任何池删除
            continue
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

  # D3（M3.0.2）：周备判定改用备份的本地日期（Asia/Shanghai）算星期，而非 UTC；
  # marker 写入 local_date/weekday/backup_ts 便于审计；轮转据此校验（坏 marker 跳过不删）。
  if [ -n "$dest" ]; then
    local dname; dname="$(basename "$dest")"
    local ld; ld="$(local_day "$dname")"
    local local_date; local_date="$(echo "$ld" | awk '{print $1}')"
    local dow; dow="$(echo "$ld" | awk '{print $2}')"
    if [ "$dow" = "7" ]; then
      printf 'local_date=%s\nweekday=%s\nbackup_ts=%s\n' "$local_date" "$dow" "$dname" > "$dest/weekly.flag"
      log "[backup] 周日备份（本地 $local_date）：写入 weekly.flag ($dname)"
    fi
  fi

  local dry=0; [ "${BACKUP_DRY_RUN:-0}" = "1" ] && dry=1
  local dname_now; dname_now="$(date -u -d "@$end_epoch" '+%Y%m%dT%H%M%SZ')"
  rotate "$dry" "$dname_now" || true

  # 下一次运行时间（本地 03:30）
  local nextrun; nextrun="$(next_0330 "$end_epoch")"

  # D2（M3.0.2）：校验失败必须判红。顺序：
  #   1) 先写 status 初值（exit_code=备份 rc），保证任何时候状态文件存在且字段齐全；
  #   2) 备份成功则跑 backup-verify.sh（它自己写 status.verify 字段），捕获其返回码；
  #   3) verify 非 0 → 把本轮 exit_code 改为专用码 7，连带 verify 字段一起回写，
  #      日志写 "verify failed" 且保留现场，**绝不打印"一轮备份完成"成功行**。
  #      这样 status.exit_code 与 status.verify.ok 永不一致的情况消失（两者同源）。
  write_status "$start" "$end" "$rc" "$dur" "$bytes" "$volumes" "$commit" "$nextrun" "$diskpct" ""

  local final_rc="$rc"
  local verify_field=""
  if [ "$rc" -eq 0 ] && [ -n "$dest" ] && [ -f "$dest/manifest.json" ]; then
    local vrc=0
    bash "$REPO/scripts/backup-verify.sh" "$dest" 2>&1 || vrc=$?
    # 读回 backup-verify 刚写入的 verify 字段（JSON 字符串），供回写时带上，避免被 write_status 覆盖丢失。
    verify_field="$(python3 - "$STATUS" <<'PY' 2>/dev/null
import json,sys
try: d=json.load(open(sys.argv[1],encoding='utf-8'))
except Exception: d={}
print(json.dumps(d.get('verify', {"ok": False, "failures": ["verify-field-missing"]}), ensure_ascii=False))
PY
)"
    [ -n "$verify_field" ] || verify_field='{"ok":false,"failures":["verify-field-unreadable"]}'
    if [ "$vrc" -ne 0 ]; then
      # verify 失败：把 verify.ok 强制置 false（保险），exit_code 改专用码 7
      verify_field="$(python3 - "$verify_field" <<'PY' 2>/dev/null
import json,sys
v=json.loads(sys.argv[1]); v['ok']=False
fl=v.get('failures') or []
if not any('verify-rc' in str(f) for f in fl): fl.append('verify-rc-nonzero')
v['failures']=fl
print(json.dumps(v,ensure_ascii=False))
PY
)"
      final_rc=7
    fi
    # 回写：exit_code 与 verify 字段同源落盘（一次原子替换）
    write_status "$start" "$end" "$final_rc" "$dur" "$bytes" "$volumes" "$commit" "$nextrun" "$diskpct" "$verify_field"
  fi

  if [ "$final_rc" -eq 7 ]; then
    log "✗ verify failed（backup-verify 返回非 0）：本轮 exit_code=7，verify 判红，保留现场 $dest"
  elif [ "$final_rc" -eq 0 ]; then
    log "✓ 一轮备份完成 rc=0 dest=$dest bytes=$bytes volumes=$volumes next_run=$nextrun"
  else
    log "✗ 一轮备份失败 rc=$final_rc（保留现场 $dest）"
  fi
  return "$final_rc"
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
用法: bash scripts/backup-daemon.sh [once|rotate|status|simulate]
  once     执行一轮备份+状态+轮转后退出（手动，支持 BACKUP_FAKE_NOW）
  simulate 轻量模拟一轮（造目录+轮转，配 BACKUP_FAKE_NOW 注入连续日期测保留策略）
  rotate   仅执行保留轮转（BACKUP_DRY_RUN=1 打印 dry-run）
  status   打印 status.json
  （run 常驻模式已移除：M3.0.3 起备份改手动 + up.sh 启动补跑，不再睡到 03:30）
环境变量：BACKUP_ROOT BACKUP_PIDFILE BACKUP_FAKE_NOW BACKUP_WATERMARK
         BACKUP_DRY_RUN BACKUP_INTERVAL_H BACKUP_LOG
EOF
}

main() {
  local cmd="${1:-status}"
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
      # D3：simulate 同样按本地日期判定周备并写带内容的 marker
      local ld; ld="$(local_day "$ts")"
      local local_date; local_date="$(echo "$ld" | awk '{print $1}')"
      local dow; dow="$(echo "$ld" | awk '{print $2}')"
      if [ "${DISABLE_WEEKLY:-0}" != "1" ] && [ "$dow" = "7" ]; then
        printf 'local_date=%s\nweekday=%s\nbackup_ts=%s\n' "$local_date" "$dow" "$ts" > "$dest/weekly.flag"
      fi
      printf '%s' "$dest" > "$ROOT/latest"
      log "[simulate] 造备份目录 $dest（fake_now=$fake）"
      rotate 0 "$ts"
      ;;
    status)
      cat "$STATUS" 2>/dev/null || { echo "无 $STATUS"; exit 1; }
      ;;
    run)
      # M3.0.3 T5（E2）：去掉 03:30 常驻守护。服务可能被关停，"睡到固定时刻"不可靠；
      # 备份改由 up.sh 启动后一次性补跑 + 手动 backup-once。保留 run 仅作兼容提示，不再常驻。
      echo "✗ backup-daemon run 常驻模式已在 M3.0.3 移除（不再睡到 03:30）：请用 make backup / make backup-once 手动备份，或由 up.sh 启动补跑。" >&2
      exit 3
      ;;
    -h|--help|help)
      usage ;;
    *)
      usage; exit 2 ;;
  esac
}

main "$@"
