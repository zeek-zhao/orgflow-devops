#!/usr/bin/env bash
# up.sh —— 顺序启动编排（v1.0 §5.3）
# 能力：五段输出 / 单服务 / --from 断点续 / DRY_RUN / --json / 失败即停 / 幂等 / 留痕。
#
# 用法：
#   up.sh                     按序起全栈，就绪断言，失败中止
#   up.sh <svc>               只起单个服务（缺依赖：打印"跳过依赖，仅起本体"继续）
#   up.sh --from <svc>        从某服务起（前面已健康则 skip (already healthy)）
#   DRY_RUN=1 up.sh           只演不跑：打印顺序/依赖/将拉取的 digest
#   FORCE_PULL=1 up.sh        强制重拉（覆盖幂等跳过）
#   JSON=1 up.sh  /  up.sh --json   机读：每步一行 JSON
#   down.sh / status.sh       见 scripts/（本文件只负责 up）
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"
COMPOSE="docker compose --env-file config/defaults.env -f docker-compose.yml"

# ---- manifest：顺序与依赖（v1.0 §5）----
ORDER=(dnsmasq certs-init ldap caddy homepage ldapadmin router)
declare -A DEPS=(
  [dnsmasq]="" [certs-init]="" [ldap]=""
  [caddy]="certs-init" [homepage]="caddy" [ldapadmin]="ldap caddy" [router]="caddy homepage ldapadmin"
)
# 镜像源（从 config/images.env 取，展示五段中的 digest）
img_of() {
  local svc="$1" key
  key="IMAGE_$(echo "$svc" | tr '[:lower:]' '[:upper:]' | tr '-' '_')"
  # 用间接变量需重新读；简单起见直接 grep
  grep -E "^${key}=" config/images.env | head -1 | cut -d= -f2-
}

MODE="full"; FROM=""; TARGET=""
# 从环境变量接收（用不同源变量，避免先重置再读把值覆盖掉）
DRY=0; FORCE=0
JSON="${JSON:-0}"                      # JSON=1 走机读
[[ "${DRY_RUN:-0}" == "1" ]] && DRY=1
[[ "${FORCE_PULL:-0}" == "1" ]] && FORCE=1
while (( $# )); do
  case "$1" in
    --json) JSON=1; shift ;;
    --from) FROM="${2:-}"; MODE="from"; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    -*) echo "未知参数: $1" >&2; exit 2 ;;
    *) TARGET="$1"; MODE="single"; shift ;;
  esac
done

start_ts=$(date +%s)

# ---- 输出原语：人读五段 / 机读 JSON ----
emit() {
  local svc="$1" phase="$2" img="$3" pull_ms="$4" cid="$5" healthy="$6" total_ms="$7" note="${8:-}"
  if (( JSON )); then
    python3.11 - "$svc" "$phase" "$img" "$pull_ms" "$cid" "$healthy" "$total_ms" "$note" <<'PY'
import json,sys
s,phase,img,pm,cid,h,tm,note=sys.argv[1:9]
print(json.dumps({"service":s,"phase":phase,"image":img,"pull_ms":int(pm or 0),
  "container_id":cid,"healthy":h,"total_ms":int(tm or 0),"note":note},ensure_ascii=False))
PY
  else
    printf '  [%s] 镜像=%s | 拉取=%sms | 容器=%s | 健康=%s | 累计=%sms %s\n' \
      "$svc" "${img:-—}" "$pull_ms" "${cid:0:12}" "$healthy" "$total_ms" "$note"
  fi
}

log_line() {
  local f="docs/records/执行日志/$(date +%F).md"
  mkdir -p "$(dirname "$f")"
  printf '\n- up.sh %s（%s）→ %s；模式=%s JSON=%s DRY=%s\n' \
    "$(date '+%H:%M:%S')" "${TARGET:-${FROM:-full}}" "$1" "$MODE" "$JSON" "$DRY" >> "$f"
}

svc_cid() {
  docker ps -aq -f "name=^of-$1\$" 2>/dev/null | head -1
}
svc_healthy() {
  local cid; cid="$(svc_cid "$1")"; [[ -z "$cid" ]] && return 1
  local st; st="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}running{{end}}' "$cid" 2>/dev/null)"
  [[ "$st" == "healthy" || "$st" == "running" ]]
}
dep_ready() {
  local svc="$1" dep
  for dep in ${DEPS[$svc]:-}; do
    if [[ "$dep" == certs-init ]]; then
      local cid; cid="$($COMPOSE ps -a -q certs-init 2>/dev/null | head -1)"
      [[ -n "$cid" && "$(docker inspect -f '{{.State.ExitCode}}' "$cid" 2>/dev/null)" == "0" ]] || return 1
    else
      svc_healthy "$dep" || return 1
    fi
  done
}
wait_healthy() {
  local svc="$1" i
  for i in $(seq 1 45); do svc_healthy "$svc" && return 0; sleep 2; done
  return 1
}

run_one() {
  local svc="$1" dep_note="" img pull_ms=0 cid healthy="—" total_ms
  # 依赖检查（单服务模式缺依赖时跳过继续，不中止）
  if ! dep_ready "$svc"; then
    dep_note="(跳过依赖，仅起本体)"
  fi
  # 幂等：已健康则跳过（FORCE 除外）
  if svc_healthy "$svc" && (( ! FORCE )); then
    total_ms=$(( $(date +%s) - start_ts )); total_ms=$((total_ms*1000))
    cid="$(svc_cid "$svc")"
    emit "$svc" "skip" "$(img_of "$svc")" 0 "$cid" "healthy" "$total_ms" "skip (already healthy) $dep_note"
    return 0
  fi
  if (( DRY )); then
    emit "$svc" "dry" "$(img_of "$svc")" 0 "" "—" 0 "$dep_note 只演不跑"
    return 0
  fi
  # 真实启动
  local t0=$(date +%s%3N)
  if [[ "$svc" == certs-init ]]; then
    $COMPOSE up -d --no-deps certs-init >/dev/null 2>&1
  else
    if (( FORCE )); then $COMPOSE pull "$svc" >/dev/null 2>&1; fi
    $COMPOSE up -d --no-deps "$svc" >/dev/null 2>&1
  fi
  local t1=$(date +%s%3N); pull_ms=$((t1-t0))
  if wait_healthy "$svc"; then healthy="healthy"; else healthy="UNHEALTHY"; fi
  cid="$(svc_cid "$svc")"
  total_ms=$(( $(date +%s%3N) - start_ts ))
  emit "$svc" "up" "$(img_of "$svc")" "$pull_ms" "$cid" "$healthy" "$total_ms" "$dep_note"
  [[ "$healthy" == "healthy" ]]
}

# ---- 选择要跑的服务序列 ----
SEQ=()
if [[ "$MODE" == "single" ]]; then
  # 校验服务名
  [[ " ${ORDER[*]} " == *" $TARGET "* ]] || { echo "未知服务: $TARGET" >&2; exit 2; }
  SEQ=("$TARGET")
elif [[ "$MODE" == "from" ]]; then
  [[ " ${ORDER[*]} " == *" $FROM "* ]] || { echo "未知服务: $FROM" >&2; exit 2; }
  for s in "${ORDER[@]}"; do
    # from 之前的：已健康 skip，否则也纳入（保证依赖）
    SEQ+=("$s")
    [[ "$s" == "$FROM" ]] && break
  done
  # 真正要从 FROM 往后全跑：重写为 FROM 及之后 + 之前仅做依赖补位
  SEQ=()
  local_seen=0
  for s in "${ORDER[@]}"; do
    if [[ "$s" == "$FROM" ]]; then local_seen=1; fi
    if (( local_seen )); then SEQ+=("$s");
    elif ! svc_healthy "$s"; then SEQ+=("$s"); fi
  done
else
  SEQ=("${ORDER[@]}")
fi

(( ! JSON )) && echo "== up.sh 顺序启动（顺序: ${SEQ[*]}）=="

failed=0; failed_at=""
for s in "${SEQ[@]}"; do
  if ! run_one "$s"; then failed=1; failed_at="$s"; break; fi
done

if (( failed )); then
  # 失败即停：打印后续未执行步数
  idx=-1; for i in "${!SEQ[@]}"; do [[ "${SEQ[$i]}" == "$failed_at" ]] && idx=$i; done
  remain=$(( ${#SEQ[@]} - idx - 1 ))
  msg="失败于 $failed_at；后续 $remain 步未执行"
  if (( JSON )); then python3.11 -c "import json;print(json.dumps({'failed':True,'at':'$failed_at','remaining':$remain}))"; else echo "✗ $msg" >&2; fi
  log_line "$msg"
  exit 1
fi

msg="全部 ${#SEQ[@]} 步 healthy"
(( JSON )) || echo "✓ $msg"
log_line "$msg"
exit 0
