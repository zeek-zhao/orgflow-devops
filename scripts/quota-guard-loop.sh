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
# m2.5.4 P0-2：新增 instances（全场 loop 实例数）与 pidfile_pid，让"双实例"在自检里可见。
#   instances    = 全场 loop 实例数，用 ps 命令行精确锚定 'bash .../quota-guard-loop.sh'
#                  （等价 pgrep -fc '[q]uota-guard-loop.sh'，但排除 nohup/watchdog 启动 wrapper
#                  的瞬时命令行，避免把 wrapper 误计为第二个实例造成假红）；
#   pidfile_pid  = daemon.pid 当前内容（正常应等于 $$；
#                  不等说明有旧 loop 晚退出覆盖了 pidfile，或出现双实例）。
count_instances() {
  # 逐 /proc/PID/cmdline 精确比对参数数组 [bash, <abs>/scripts/quota-guard-loop.sh]。
  # 排除命令替换 $(count_instances) fork 的子 shell（其 cmdline 继承 loop、PPID=本 loop），
  # 否则会把子 shell 误计为第二实例。QUOTA_SELF_PID=$$ 为本 loop PID，只过滤其直接子进程，
  # 不排除本 loop 自身，也不影响 watchdog 另起的其他 loop（双实例）。
  QUOTA_SELF_PID="$$" python3 - 2>/dev/null <<'PY' || echo 0
import os, glob
self_pid = int(os.environ.get('QUOTA_SELF_PID', '0'))
def ppid(pid):
    try:
        for line in open('/proc/%d/status' % pid):
            if line.startswith('PPid:'):
                return int(line.split()[1])
    except Exception:
        pass
    return -1
n = 0
for d in glob.glob('/proc/[0-9]*/cmdline'):
    try:
        pid = int(d.split('/')[2])
        argv = [a.decode(errors='replace') for a in open(d, 'rb').read().split(b'\0') if a]
    except Exception:
        continue
    if len(argv) == 2 and os.path.basename(argv[0]) == 'bash' and (argv[1].endswith('/scripts/quota-guard-loop.sh') or argv[1] == 'scripts/quota-guard-loop.sh' or argv[1].endswith('/quota-guard-loop.sh') and '/scripts/' in argv[1]):
        if ppid(pid) == self_pid:  # 命令替换 fork 的子 shell（cmdline 继承父），非独立 loop
            continue
        n += 1
print(n)
PY
}
write_alive() {
  local ts pid args alive logts esc instances pidfile_pid
  ts="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  pid="$$"
  args="$(ps -p "$pid" -o args= 2>/dev/null | tr -d '\n' | tr -d '\r')"
  alive=false
  printf '%s' "$args" | grep -q 'quota-guard-loop.sh' && alive=true
  logts=""
  [ -f "$LOG" ] && logts="$(date -u -r "$LOG" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null)"
  instances="$(count_instances)"
  pidfile_pid="$(cat "$OUT/daemon.pid" 2>/dev/null | tr -d '\r\n')"
  [ -n "$pidfile_pid" ] || pidfile_pid=0
  esc="$(printf '%s' "$args" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')"
  printf '{"ts":"%s","pid":%s,"args":"%s","alive":%s,"mechanism":"%s","log_last_ts":"%s","instances":%s,"pidfile_pid":%s}\n' \
    "$ts" "$pid" "$esc" "$alive" "$MECH" "$logts" "$instances" "$pidfile_pid" > "$OUT/alive.json"
}

do_guard() { bash "$ROOT/scripts/quota-guard.sh" --container "$CONTAINER" --out "$OUT"; }

refresh_loop() {
  rotate_log
  # m2.5.5 P0-1：心跳即续约——每轮开头重写自己的 pidfile。
  # 旧实现只在启动时写一次，pidfile 被 cleanup/误删后永不重建，导致 alive.pidfile_pid=0、
  # 单实例判据永远对不上（自检红）。每轮 echo 保证删后 ≤INTERVAL（默认 5min）自愈。
  echo "$$" > "$OUT/daemon.pid"
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
  # m2.5.5 P0-1：给 cleanup 守卫复用同一套精确计数（避免两处规则漂移）。
  # 本进程 argv=[bash,script,--count-instances] 长度≠2，不会把自己计入；其 python 子进程同理。
  --count-instances) count_instances; exit 0 ;;
  -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
  "") ;;
  *) echo "[quota-loop] ✗ 未知参数: $1" >&2; exit 3 ;;
esac

echo "[quota-loop] 启动：mechanism=$MECH interval=${INTERVAL}s container=$CONTAINER log=$LOG"
# m2.5.5 P0-1：启动守卫——若 pidfile 已指向另一个"存活且确为 loop"的进程，拒绝启动并 exit 4，
# 防止 supervisor 的 autorestart 与 watchdog 在同一时刻各自拉起、形成双实例双写。
# 判定三条同时成立才算"别人持有"：pidfile 非空、PID≠自身、kill -0 存活、cmdline 含 quota-guard-loop.sh。
oldpid="$(cat "$OUT/daemon.pid" 2>/dev/null | tr -d '\r\n')"
if [ -n "$oldpid" ] && [ "$oldpid" != "$$" ] && kill -0 "$oldpid" 2>/dev/null \
   && ps -p "$oldpid" -o args= 2>/dev/null | grep -qF 'quota-guard-loop.sh'; then
  echo "[quota-loop] ✗ pidfile 指向存活 loop PID=$oldpid（≠自身 $$），拒绝启动避免双实例（exit 4）" >&2
  exit 4
fi
# 常驻模式写 daemon.pid（自报 PID）；supervisor/runit/nohup 统一据此判活，
# 重启后新进程会覆盖旧 PID。--once 模式（cron）不写 pidfile。
echo "$$" > "$OUT/daemon.pid"
# m2.5.4 P0-1：只删"自己的" pidfile。旧 loop 晚退出时若无条件 rm，会把新 loop 的 pidfile
# 删掉，watchdog 看到"无 pidfile"再拉一个 → 三实例双写。先比对 pidfile 内容 == 自身 PID 才删。
trap 'if [ "$(cat "$OUT/daemon.pid" 2>/dev/null | tr -d "\r\n")" = "$$" ]; then rm -f "$OUT/daemon.pid"; fi' EXIT INT TERM
# m2.5.4 P0-2：启动瞬间 nohup/setsid wrapper 的 cmdline 可能短暂与 loop 完全相同，
# 延后 5s 再首次刷新，确保 wrapper 已 exec/退出，避免首次 alive.instances 误计为 2（假红）。
sleep 5
while true; do
  refresh_loop
  sleep "$INTERVAL"
done
