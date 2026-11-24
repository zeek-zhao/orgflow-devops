#!/usr/bin/env bash
# Jenkins Job 冒烟（M1 T8）：调 Jenkins API 触发全部 verify-* Job → 等结果 →
# 下载每次构建的 consoleText 到 artifacts/jenkins-smoke/<UTC时间戳>/，写 summary。
# 纯 bash + curl + python3（主机侧），不引入 jq。口令只走环境变量/文件，绝不写入脚本或产物。
#
# 两种执行通道：
#   1) 主机侧直连（默认）：JENKINS_URL 指向可达的 Jenkins（--noproxy '*' 绕代理）。
#   2) 容器内通道：设 JENKINS_CONTAINER=of-jenkins 时，所有 API 调用改走
#      `docker exec <容器> curl http://localhost:8080/jenkins/...`。用于反代下 crumb
#      校验失效（POST 403）的环境——容器内 localhost 不受反代 Host/MITM 影响。
#
# 用法见 docs/services/jenkins.md「冒烟测试」节；退出码：全 SUCCESS=0，失败/超时=1，参数/认证问题=2。
set -uo pipefail
cd "$(dirname "$0")/.."

ENVF="config/defaults.env"
JURL="${JENKINS_URL:-$(sed -n 's/^JENKINS_URL=//p' "$ENVF" | head -1)}"
JURL="${JURL%/}"
USER_="${JENKINS_USER:-jenkins-ci}"
PASS_="${JENKINS_PASS:-}"
[[ -z "$PASS_" && -n "${JENKINS_PASS_FILE:-}" ]] && PASS_="$(cat "$JENKINS_PASS_FILE")"
if [[ -z "$PASS_" || -z "$JURL" ]]; then
  echo "缺 JENKINS_URL/JENKINS_PASS：口令见 docs/services/jenkins.md，用 env 或 JENKINS_PASS_FILE 提供" >&2
  exit 2
fi

TIMEOUT=900; ONLY=""; WAIT=1; DRY=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --only) ONLY="$2"; shift 2;;
    --timeout) TIMEOUT="$2"; shift 2;;
    --no-wait) WAIT=0; shift;;
    --dry-run) DRY=1; shift;;
    -h|--help) echo "用法：$0 [--only job1,job2] [--timeout 900] [--no-wait] [--dry-run]"; echo "环境：JENKINS_URL/JENKINS_USER/JENKINS_PASS(JENKINS_PASS_FILE)/JENKINS_CONTAINER(可选)"; exit 0;;
    *) echo "未知参数 $1" >&2; exit 2;;
  esac
done

# 统一的 API 调用：主机侧 curl 或容器内 docker exec curl。
# 约定：$URL_PATH 以 / 开头（相对 /jenkins 根），调用处拼 $JURL$URL_PATH。
CT="${JENKINS_CONTAINER:-}"
api() {
  # 用法：api <curl额外参数...> <完整URL>   （URL 为最后一个参数）
  local last="${@: -1}" pre=("${@:1:$#-1}") sub
  if [[ -n "$CT" ]]; then
    # 容器内：注入认证，URL 只留 /jenkins 及其后路径；跳过代理（容器无需）。
    sub="${last#*jenkins}"   # 形如 /api/json?tree=... 或空
    docker exec "$CT" curl -sS -g -u "$USER_:$PASS_" "${pre[@]}" "http://localhost:8080/jenkins$sub"
  else
    curl -sS -g --noproxy '*' -u "$USER_:$PASS_" "${pre[@]}" "$last"
  fi
}

TS="$(date -u +%Y%m%dT%H%M%SZ)"; OUT="artifacts/jenkins-smoke/$TS"; mkdir -p "$OUT"

# crumb：主机侧需 cookie jar 保持会话；容器内同样用 cookie jar 更稳。
CJ="$OUT/.crumb.cookie"; rm -f "$CJ"
if [[ -n "$CT" ]]; then
  CRUMB_JSON="$(docker exec "$CT" sh -c "curl -s -c /tmp/smoke.cj -u '$USER_:$PASS_' 'http://localhost:8080/jenkins/crumbIssuer/api/json'" 2>/dev/null)"
  docker cp "$CT:/tmp/smoke.cj" "$CJ" >/dev/null 2>&1 || true
else
  CRUMB_JSON="$(curl -sS -g --noproxy '*' -c "$CJ" -u "$USER_:$PASS_" --max-time 20 "$JURL/crumbIssuer/api/json")"
fi
CRUMB="$(printf '%s' "$CRUMB_JSON" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("crumb",""))' 2>/dev/null)"
if [[ -z "$CRUMB" ]]; then
  echo "crumb 解析失败（认证失败或通道不通；反代 403 时可设 JENKINS_CONTAINER=of-jenkins）" >&2
  exit 2
fi
CRUMB_FIELD="$(printf '%s' "$CRUMB_JSON" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("crumbRequestField","Jenkins-Crumb"))' 2>/dev/null || echo Jenkins-Crumb)"

JOBS_JSON="$(api --max-time 20 "$JURL/api/json?tree=jobs[name]")"
JOBS="$(printf '%s' "$JOBS_JSON" | python3 -c 'import sys,json;print(" ".join(j["name"] for j in json.load(sys.stdin)["jobs"] if j["name"].startswith("verify-")))' 2>/dev/null)"
[[ -n "$ONLY" ]] && JOBS="$(echo "$ONLY" | tr ',' ' ')"
[[ -z "$JOBS" ]] && { echo "未发现 verify-* Job（JCasC/Job DSL 是否正常？）" >&2; exit 2; }

rc=0; : > "$OUT/summary.txt"
for job in $JOBS; do
  if [[ "$DRY" == 1 ]]; then echo "[dry-run] $job"; continue; fi

  # 参数化 Job：buildWithParameters?SERVICE=<svc>（svc = job 名去掉 verify- 前缀）。
  svc="${job#verify-}"
  trig_code=""
  if [[ -n "$CT" ]]; then
    trig_code="$(docker exec "$CT" sh -c "curl -s -o /dev/null -w '%{http_code}' -b /tmp/smoke.cj -X POST -u '$USER_:$PASS_' -H '$CRUMB_FIELD: $CRUMB' 'http://localhost:8080/jenkins/job/$job/buildWithParameters?SERVICE=$svc'" 2>/dev/null)"
  else
    trig_code="$(curl -sS -g --noproxy '*' -o /dev/null -w '%{http_code}' -b "$CJ" -X POST -u "$USER_:$PASS_" -H "$CRUMB_FIELD: $CRUMB" --max-time 20 "$JURL/job/$job/buildWithParameters?SERVICE=$svc" 2>/dev/null)"
  fi
  # 无参数 Job（如 verify-jenkins-agent / verify-lan-all）用 buildWithParameters 会 400，退回 /build。
  if [[ "$trig_code" == "400" || "$trig_code" == "404" ]]; then
    if [[ -n "$CT" ]]; then
      trig_code="$(docker exec "$CT" sh -c "curl -s -o /dev/null -w '%{http_code}' -b /tmp/smoke.cj -X POST -u '$USER_:$PASS_' -H '$CRUMB_FIELD: $CRUMB' 'http://localhost:8080/jenkins/job/$job/build'" 2>/dev/null)"
    else
      trig_code="$(curl -sS -g --noproxy '*' -o /dev/null -w '%{http_code}' -b "$CJ" -X POST -u "$USER_:$PASS_" -H "$CRUMB_FIELD: $CRUMB" --max-time 20 "$JURL/job/$job/build" 2>/dev/null)"
    fi
  fi
  if [[ "$trig_code" != "201" && "$trig_code" != "302" ]]; then
    echo "$job 触发失败（HTTP $trig_code）" | tee -a "$OUT/summary.txt"; rc=1; continue
  fi

  # 队列号 → build number（--no-wait 时只触发不轮询）。
  qn=""
  for i in $(seq 1 30); do
    u="$(api "$JURL/job/$job/api/json?tree=queueItem[url]" | python3 -c 'import sys,json;d=json.load(sys.stdin);print((d.get("queueItem") or {}).get("url",""))' 2>/dev/null)"
    [[ -n "$u" ]] && { qn="${u%/}"; qn="${qn##*/}"; break; }; sleep 1
  done
  if [[ "$WAIT" == 0 ]]; then printf '%-24s queued=%s (--no-wait)\n' "$job" "$qn" | tee -a "$OUT/summary.txt"; continue; fi
  [[ -z "$qn" ]] && { echo "$job 未进入队列" | tee -a "$OUT/summary.txt"; rc=1; continue; }

  n=""
  for i in $(seq 1 180); do
    n="$(api "$JURL/queue/item/$qn/api/json" | python3 -c 'import sys,json;d=json.load(sys.stdin);print((d.get("executable") or {}).get("number",""))' 2>/dev/null)"
    [[ -n "$n" ]] && break; sleep 1
  done
  [[ -z "$n" ]] && { echo "$job 排队超时" | tee -a "$OUT/summary.txt"; rc=1; continue; }

  end=$((SECONDS+TIMEOUT)); st="False|null|0"
  while (( SECONDS < end )); do
    st="$(api "$JURL/job/$job/$n/api/json?tree=building,result,duration" | python3 -c 'import sys,json;d=json.load(sys.stdin);print("%s|%s|%s"%(d.get("building"),d.get("result"),d.get("duration",0)))' 2>/dev/null)"
    [[ "${st%%|*}" == "False" ]] && break; sleep 5
  done
  res="${st#*|}"; res="${res%%|*}"; dur="${st##*|}"
  # 不用 curl -o：容器内通道的 -o 会写到容器文件系统；统一捕获 stdout 再重定向到宿主文件。
  api "$JURL/job/$job/$n/consoleText" > "$OUT/$job-$n.log"

  if [[ ! -s "$OUT/summary.md" ]]; then printf '| Job | # | 结果 | 耗时 | 日志 |\n|---|---|---|---|---|\n' > "$OUT/summary.md"; fi
  printf '%-24s #%-3s %-8s %ss  log=%s\n' "$job" "$n" "$res" "$((dur/1000))" "$OUT/$job-$n.log" | tee -a "$OUT/summary.txt"
  printf '| %s | #%s | %s | %ss | %s |\n' "$job" "$n" "$res" "$((dur/1000))" "$job-$n.log" >> "$OUT/summary.md"
  [[ "$res" == "SUCCESS" ]] || rc=1
done

rm -f "$CJ"
echo "日志与汇总：$OUT"; exit $rc
