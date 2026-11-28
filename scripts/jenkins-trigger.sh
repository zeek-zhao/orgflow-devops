#!/usr/bin/env bash
# jenkins-trigger.sh —— 触发单个 Job 并等待结果、打印 console（m2.5.3 验收辅助）
# 用法：JENKINS_PASS=... bash scripts/jenkins-trigger.sh <job> [paramsQuery] [timeoutMin]
#   timeoutMin：等待结果的上限（分钟，默认 6）；m3.0.5 T4 由 verify-all.sh 按 checks.tsv 传入。
#   超时以 exit 5 + "result: TIMEOUT" 结束，调用方据此判 FAIL(timeout)，不写 UNKNOWN。
set -uo pipefail
JURL="${JENKINS_URL:-http://127.0.0.1:18081/jenkins}"; JURL="${JURL%/}"
U="${JENKINS_USER:-jenkins-ci}"; P="${JENKINS_PASS:-}"
JOB="${1:-}"; QUERY="${2:-}"; TIMEOUT_MIN="${3:-${TIMEOUT_MIN:-6}}"
# 等待上限换算为轮询次数（每次 sleep 3s）。校验为正整数，非法则回落默认 6。
case "$TIMEOUT_MIN" in ''|*[!0-9]*) TIMEOUT_MIN=6;; esac
[ "$TIMEOUT_MIN" -gt 0 ] 2>/dev/null || TIMEOUT_MIN=6
WAIT_N=$(( TIMEOUT_MIN * 60 / 3 ))
[[ -n "$JOB" && -n "$P" ]] || { echo "usage: jenkins-trigger.sh <job> [paramsQuery] (需 JENKINS_PASS)" >&2; exit 2; }
CJ=/tmp/jt.cookie; rm -f "$CJ"
CRUMB_JSON="$(curl -sS --noproxy '*' -c "$CJ" -u "$U:$P" "$JURL/crumbIssuer/api/json")"
CRUMB="$(printf '%s' "$CRUMB_JSON" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("crumb",""))' 2>/dev/null)"
[[ -n "$CRUMB" ]] || { echo "crumb 失败" >&2; exit 2; }
api() { curl -sgS --noproxy '*' -u "$U:$P" "$1"; }
# 记录触发前最大 build number
before="$(api "$JURL/job/$JOB/api/json?tree=lastBuild[number]" | python3 -c 'import sys,json;d=json.load(sys.stdin);print((d.get("lastBuild") or {}).get("number",0))' 2>/dev/null || echo 0)"
turl="$JURL/job/$JOB/build"; [ -n "$QUERY" ] && turl="$JURL/job/$JOB/buildWithParameters?$QUERY"
code="$(curl -sS --noproxy '*' -o /dev/null -w '%{http_code}' -b "$CJ" -u "$U:$P" -X POST -H "Jenkins-Crumb: $CRUMB" "$turl")"
echo "trigger=$code (before=$before)"
[[ "$code" == 201 || "$code" == 302 ]] || exit 3
n=""
for i in $(seq 1 45); do
  cur="$(api "$JURL/job/$JOB/api/json?tree=lastBuild[number,building]" | python3 -c 'import sys,json;d=json.load(sys.stdin);b=d.get("lastBuild") or {};print(b.get("number",0),b.get("building"))' 2>/dev/null)"
  num="$(echo "$cur" | awk '{print $1}')"; bld="$(echo "$cur" | awk '{print $2}')"
  if [ -n "$num" ] && [ "$num" -gt "$before" ] 2>/dev/null; then n="$num"; break; fi
  sleep 2
done
[[ -n "$n" ]] || { echo "未等到新构建" >&2; echo "result: TIMEOUT"; exit 5; }
echo "build #$n (wait_limit=${TIMEOUT_MIN}min / ${WAIT_N} polls)"
timed_out=1
for i in $(seq 1 "$WAIT_N"); do
  st="$(api "$JURL/job/$JOB/$n/api/json?tree=building,result,duration" | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d.get("building"),d.get("result"),d.get("duration",0))' 2>/dev/null)"
  if [ "${st%% *}" = "False" ]; then timed_out=0; break; fi
  sleep 3
done
if [ "$timed_out" -ne 0 ]; then
  echo "result: TIMEOUT (等待超过 ${TIMEOUT_MIN}min，build #$n 仍在运行)"
  echo "=== console (tail 40) ==="
  api "$JURL/job/$JOB/$n/consoleText" | tail -40
  exit 5
fi
echo "result: $st"
echo "=== console (tail 40) ==="
api "$JURL/job/$JOB/$n/consoleText" | tail -40
