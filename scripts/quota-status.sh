#!/usr/bin/env bash
# quota-status.sh —— 配额证据新鲜度 + 当前生效刷新机制查看（m2.5.1 P0-1 / m2.5.3 P0-2）
# 部署后、推代码前必跑：打印 mechanism=<systemd-timer|cron|supervisor|runit|nohup|none>
# + 门禁消费证据 artifacts/quota/latest-of-builder.json 的 ts/age/result；
# age>10min 返回非 0（此时推 change 必被拦）。
#
# 机制判定优先级（高→低）：systemd-timer → supervisor → runit → cron → nohup → none。
# 优先读 artifacts/quota/mechanism.txt（安装目标写入的声明），再用进程/服务状态二次校验；
# 声明与进程实际状态不一致时以进程实际状态为准并给出 ⚠ 提示（防止"写了就算装好"的假绿）。
#
# 退出码: 0=证据新鲜(≤10min)  1=过期/缺失/非法/机制声明与进程不一致
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
Q="$ROOT/artifacts/quota/latest-of-builder.json"
MQ="$ROOT/artifacts/quota/mechanism.txt"
MAX_MIN=10

echo "== OrgFlow 配额证据状态 =="

# ---------- 判定当前生效刷新机制 ----------
process_alive() {  # $1=pid  $2=命令行关键字
  local pid="${1:-}" kw="${2:-quota-guard-loop.sh}"
  [ -n "$pid" ] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  # 不只 kill -0：比对命令行，避免 PID 复用误判（m2.5.3 P0-2）。
  ps -p "$pid" -o args= 2>/dev/null | grep -qF "$kw"
}

declared=""
[ -f "$MQ" ] && declared="$(cat "$MQ" 2>/dev/null | tr -d '\r\n')"

mech="none"; mech_detail=""
if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ] \
   && systemctl is-active --quiet orgflow-quota.timer 2>/dev/null; then
  mech="systemd-timer"
  mech_detail="next=$(systemctl show orgflow-quota.timer -p NextElapseUSecRealtime --value 2>/dev/null || echo n/a)"
elif command -v supervisorctl >/dev/null 2>&1 \
     && supervisorctl status orgflow-quota 2>/dev/null | grep -qE 'RUNNING|STARTING'; then
  mech="supervisor"
  mech_detail="$(supervisorctl status orgflow-quota 2>/dev/null | head -1)"
elif command -v sv >/dev/null 2>&1 && [ -e /etc/sv/orgflow-quota/run ] \
     && sv status orgflow-quota 2>/dev/null | grep -q '^run:'; then
  mech="runit"
  mech_detail="$(sv status orgflow-quota 2>/dev/null | head -1)"
else
  # 非 systemd/supervisor/runit：按声明 + 进程实际状态判定 cron / nohup。
  # supervisor 在无 supervisorctl CLI 但 XML-RPC 可用时，认声明 + daemon 进程存活。
  cron_line=""
  if command -v crontab >/dev/null 2>&1; then
    cron_line="$(crontab -l 2>/dev/null | grep -F 'quota-guard' | head -1 || true)"
  fi
  if [ -z "$cron_line" ] && [ -f /etc/cron.d/orgflow-quota ]; then
    cron_line="$(grep -F 'quota-guard' /etc/cron.d/orgflow-quota 2>/dev/null | head -1 || true)"
  fi
  dpid=""
  if [ -f "$ROOT/artifacts/quota/daemon.pid" ]; then
    cand="$(cat "$ROOT/artifacts/quota/daemon.pid" 2>/dev/null | tr -d '\r\n')"
    process_alive "$cand" && dpid="$cand"
  fi
  if [ "$declared" = "supervisor" ] && [ -n "$dpid" ]; then
    mech="supervisor"
    # m2.5.4 P0-2：声明 supervisor 但服务非 RUNNING 时，把真实 state 显示出来
    # （supervisorctl 可用读之；否则 socket 可用时经 rpc 读），避免笼统显示 supervisor 掩盖 FATAL/BACKOFF。
    svc_state=""
    if command -v supervisorctl >/dev/null 2>&1; then
      svc_state="$(supervisorctl status orgflow-quota 2>/dev/null | awk '{print $2}')"
    elif [ -n "${SUPERVISOR_SOCKET:-}" ] && [ -f "$ROOT/scripts/supervisor-rpc.py" ]; then
      svc_state="$(SUPERVISOR_SOCKET="$SUPERVISOR_SOCKET" python3 "$ROOT/scripts/supervisor-rpc.py" status orgflow-quota 2>/dev/null | awk '{print $2}')"
    fi
    case "$svc_state" in
      RUNNING|STARTING) mech_detail="PID=$dpid（supervisord 托管，state=$svc_state）" ;;
      FATAL|BACKOFF|STOPPED|UNKNOWN|SHUTDOWN) mech_detail="PID=$dpid（⚠ supervisor state=$svc_state，服务非 RUNNING）" ;;
      *) mech_detail="PID=$dpid（supervisord 托管，无 supervisorctl CLI，按声明+进程判活）" ;;
    esac
  elif [ -n "$cron_line" ]; then
    mech="cron"; mech_detail="$(printf '%s' "$cron_line" | sed 's/>>.*/>> .../')"
  elif [ "$declared" = "runit" ] && [ -n "$dpid" ]; then
    mech="runit"; mech_detail="PID=$dpid"
  elif [ -n "$dpid" ]; then
    mech="nohup"; mech_detail="PID=$dpid"
  fi
fi

if [ -n "$mech_detail" ]; then
  echo "  mechanism=$mech  [$mech_detail]"
else
  echo "  mechanism=$mech"
fi
if [ -n "$declared" ] && [ "$declared" != "$mech" ]; then
  case "$declared:$mech" in
    supervisor:cron|supervisor:nohup|runit:nohup|runit:cron|cron:nohup) ;;
    *) echo "  ⚠ mechanism.txt 声明=$declared，但实际判定=$mech（以实际进程为准，请检查安装）" ;;
  esac
fi
if [ "$mech" = "none" ]; then
  echo "  ✗ 无任何自动刷新机制（systemd-timer/supervisor/runit/cron/nohup 均未生效）：证据必将 stale"
fi

echo "  证据文件: $Q"
if [ ! -f "$Q" ]; then
  echo "  ✗ 证据缺失（container==of-builder 的门禁证据不存在）；先跑 make quota-guard"
  exit 1
fi
if command -v jq >/dev/null 2>&1; then
  ts="$(jq -r '.ts // empty' "$Q")"; verdict="$(jq -r '.verdict // empty' "$Q")"
  container="$(jq -r '.container // empty' "$Q")"; result="$(jq -r '.result // empty' "$Q")"
else
  ts="$(python3 -c "import json;print(json.load(open('$Q')).get('ts',''))" 2>/dev/null)"
  verdict="$(python3 -c "import json;print(json.load(open('$Q')).get('verdict',''))" 2>/dev/null)"
  container="$(python3 -c "import json;print(json.load(open('$Q')).get('container',''))" 2>/dev/null)"
  result="$(python3 -c "import json;print(json.load(open('$Q')).get('result',''))" 2>/dev/null)"
fi
[ -n "$ts" ] || { echo "  ✗ 证据 ts 缺失/JSON 非法"; exit 1; }

ets=$(date -u -d "$ts" +%s 2>/dev/null || echo 0)
now=$(date -u +%s)
if [ "$ets" -le 0 ]; then echo "  ✗ 证据 ts 非法: $ts"; exit 1; fi
age_sec=$(( now - ets )); age_min=$(( age_sec / 60 ))
echo "  ts=$ts  verdict=$verdict  result=$result  container=$container  age=${age_min}min (阈值 ${MAX_MIN}min)"

rc=0
[ "$verdict" = "PASS" ] || { echo "  ✗ verdict 非 PASS: $verdict"; rc=1; }
[ "$result" = "PASS" ] || { echo "  ✗ result 非 PASS: $result"; rc=1; }
[ "$container" = "of-builder" ] || { echo "  ✗ container 非 of-builder: $container"; rc=1; }
if [ "$age_min" -gt "$MAX_MIN" ]; then
  echo "  ✗ 证据过期 ${age_min}min > ${MAX_MIN}min：推 change 会被 Quota gate BLOCKED（刷新：make quota-guard / 等自动刷新）"
  rc=1
else
  [ "$rc" -eq 0 ] && echo "  ✓ 证据新鲜（age=${age_min}min ≤ ${MAX_MIN}min），可推代码"
fi
exit "$rc"
