#!/usr/bin/env bash
# up.sh —— M0-v2 逐服务编排（去顶层 Compose，文档 R3 / C-3）
# 每个服务用 docker compose -f services/<svc>/compose.yml 单独起；网络/卷 external 幂等预建。
# 顺序/依赖取 services/manifest.tsv；零停机：存在即跳过，禁 --force/down/prune。
#
# 用法：
#   up.sh                       按 manifest 顺序起全栈
#   up.sh --only <svc>          单起（等价于旧的位置参数）
#   up.sh --from <svc>          从某服务起（前面已健康则跳过）
#   up.sh --no-pull             不拉镜像（默认会 pull）
#   up.sh --dry-run             只演不跑
#   up.sh --json                机读：每步一行 JSON
#   up.sh <svc>                 兼容旧写法 = --only <svc>
#   DRY_RUN=1 / FORCE_PULL=1 / JSON=1 环境变量同样生效
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"
ENVFILE="config/defaults.env"

# ---- 读 manifest（顺序 + 依赖 + 健康地址）----
declare -a ORDER=()
declare -A DEPS=() HEALTHURL=()
while IFS=$'\t' read -r order svc deps health monitor ping path tags kind; do
  [[ "$svc" == "service" || -z "$svc" ]] && continue
  ORDER+=("$svc"); DEPS["$svc"]="$deps"; HEALTHURL["$svc"]="$health"
done < <(python3.11 -c "import csv; [print('\t'.join([r['order'],r['service'],r['depends_on'],r['health_url'],r['monitor_url'],r['ping_url'],r['public_path'],r['tags'],r['ui_kind']])) for r in csv.DictReader(open('services/manifest.tsv',encoding='utf-8-sig'),delimiter='\t')]")

svc_project() { echo "orgflow-$1"; }
svc_compose() { echo "services/$1/compose.yml"; }
DC() { docker compose --env-file "$ENVFILE" -p "$(svc_project "$1")" -f "$(svc_compose "$1")"; }

# ---- 资源真源（defaults.env 注入，带 orgflow-minimal_ 前缀 = §2.5 第0步真实名）----
NET="$(grep -E '^ORG_NETWORK=' "$ENVFILE" | cut -d= -f2-)"
V_CA="$(grep -E '^CA_DATA_VOLUME=' "$ENVFILE" | cut -d= -f2-)"
V_LDAPD="$(grep -E '^LDAP_DATA_VOLUME=' "$ENVFILE" | cut -d= -f2-)"
V_LDAPC="$(grep -E '^LDAP_CONFIG_VOLUME=' "$ENVFILE" | cut -d= -f2-)"
SUBNET="$(grep -E '^NET_SUBNET=' "$ENVFILE" | cut -d= -f2-)"

# ---- 参数 ----
MODE="full"; FROM=""; TARGET=""
DRY=0; FORCE=0; PULL=1
JSON="${JSON:-0}"
[[ "${DRY_RUN:-0}" == "1" ]] && DRY=1
[[ "${FORCE_PULL:-0}" == "1" ]] && FORCE=1
while (( $# )); do
  case "$1" in
    --json) JSON=1; shift ;;
    --from) FROM="${2:-}"; MODE="from"; shift 2 ;;
    --only) TARGET="${2:-}"; MODE="single"; shift 2 ;;
    --no-pull) PULL=0; shift ;;
    --dry-run) DRY=1; shift ;;
    -h|--help) sed -n '2,14p' "$0"; exit 0 ;;
    -*) echo "未知参数: $1" >&2; exit 2 ;;
    *) TARGET="$1"; MODE="single"; shift ;;
  esac
done
start_ts=$(date +%s)

emit() {
  local svc="$1" phase="$2" img="$3" ms="$4" cid="$5" healthy="$6" note="${7:-}"
  if (( JSON )); then
    python3.11 - "$svc" "$phase" "$img" "$ms" "$cid" "$healthy" "$note" <<'PY'
import json,sys
s,ph,img,ms,cid,h,note=sys.argv[1:8]
print(json.dumps({"service":s,"phase":ph,"image":img,"ms":int(ms or 0),"container":cid,"healthy":h,"note":note},ensure_ascii=False))
PY
  else
    printf '  [%s] %s | 镜像=%s | 容器=%s | 健康=%s | %sms %s\n' \
      "$svc" "$phase" "${img:-—}" "${cid:0:12}" "$healthy" "$ms" "$note"
  fi
}
log_line() {
  local f="docs/records/执行日志/$(date +%F).md"; mkdir -p "$(dirname "$f")"
  printf '\n- up.sh %s（%s）→ %s；模式=%s JSON=%s DRY=%s\n' "$(date '+%H:%M:%S')" "${TARGET:-${FROM:-full}}" "$1" "$MODE" "$JSON" "$DRY" >> "$f"
}
img_of() { grep -E "^IMAGE_$(echo "$1"|tr 'a-z-' 'A-Z_')=" config/images.env 2>/dev/null | head -1 | cut -d= -f2-; }

# ---- 幂等预建网络/卷（存在即跳过，禁 --force / 禁先 rm）----
res_note() { (( JSON )) || echo "[res] $1"; }
ensure_resources() {
  if docker network inspect "$NET" >/dev/null 2>&1; then
    res_note "网络 $NET 已存在，跳过"
  else
    (( DRY )) && { res_note "[dry] 将建网络 $NET $SUBNET"; return 0; }
    docker network create --driver bridge --subnet "$SUBNET" "$NET" >/dev/null
    res_note "✓ 建网络 $NET $SUBNET"
  fi
  for v in "$V_CA" "$V_LDAPD" "$V_LDAPC"; do
    if docker volume inspect "$v" >/dev/null 2>&1; then
      res_note "卷 $v 已存在，跳过"
    else
      (( DRY )) && { res_note "[dry] 将建卷 $v"; continue; }
      docker volume create "$v" >/dev/null
      res_note "✓ 建卷 $v"
    fi
  done
}

svc_cid() { docker ps -aq -f "name=^of-$1\$" 2>/dev/null | head -1; }
svc_healthy() {
  local cid; cid="$(svc_cid "$1")"; [[ -z "$cid" ]] && return 1
  local st; st="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}running{{end}}' "$cid" 2>/dev/null)"
  [[ "$st" == "healthy" || "$st" == "running" || "$st" == "exited" ]]
}
dep_ready() {
  local svc="$1" dep
  for dep in ${DEPS[$svc]//,/ }; do
    [[ -z "$dep" ]] && continue
    if [[ "$dep" == certs-init ]]; then
      local cid; cid="$(svc_cid certs-init)"
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
  local svc="$1" t0 t1 cid healthy="—" img note=""
  if ! dep_ready "$svc"; then note="(依赖未就绪，跳过依赖仅起本体)"; fi
  # dry-run 优先：无论是否已健康，都只演不跑（§8.3 要 dry-run 输出 manifest 顺序）
  if (( DRY )); then emit "$svc" "dry" "$(img_of "$svc")" 0 "" "—" "只演不跑 $note"; return 0; fi
  if svc_healthy "$svc" && (( ! FORCE )); then
    cid="$(svc_cid "$svc")"; emit "$svc" "skip" "$(img_of "$svc")" 0 "$cid" "healthy" "skip (already healthy) $note"; return 0
  fi
  t0=$(date +%s%3N)
  if (( PULL )); then DC "$svc" pull >/dev/null 2>&1; fi
  DC "$svc" up -d --no-deps "$svc" >/dev/null 2>&1
  t1=$(date +%s%3N)
  if wait_healthy "$svc"; then healthy="healthy"; else healthy="UNHEALTHY"; fi
  cid="$(svc_cid "$svc")"
  emit "$svc" "up" "$(img_of "$svc")" "$((t1-t0))" "$cid" "$healthy" "$note"
  [[ "$healthy" == "healthy" ]]
}

SEQ=()
if [[ "$MODE" == "single" ]]; then
  [[ " ${ORDER[*]} " == *" $TARGET "* ]] || { echo "未知服务: $TARGET" >&2; exit 2; }
  SEQ=("$TARGET")
elif [[ "$MODE" == "from" ]]; then
  [[ " ${ORDER[*]} " == *" $FROM "* ]] || { echo "未知服务: $FROM" >&2; exit 2; }
  seen=0
  for s in "${ORDER[@]}"; do
    [[ "$s" == "$FROM" ]] && seen=1
    if (( seen )) || ! svc_healthy "$s"; then SEQ+=("$s"); fi
  done
else
  SEQ=("${ORDER[@]}")
fi

(( ! JSON )) && echo "== up.sh 逐服务顺序启动（顺序: ${SEQ[*]}）=="
ensure_resources
failed=0; failed_at=""
for s in "${SEQ[@]}"; do
  if ! run_one "$s"; then failed=1; failed_at="$s"; break; fi
done

if (( failed )); then
  idx=-1; for i in "${!SEQ[@]}"; do [[ "${SEQ[$i]}" == "$failed_at" ]] && idx=$i; done
  remain=$(( ${#SEQ[@]} - idx - 1 ))
  if (( JSON )); then python3.11 -c "import json;print(json.dumps({'failed':True,'at':'$failed_at','remaining':$remain}))"; else echo "✗ 失败于 $failed_at；后续 $remain 步未执行" >&2; fi
  log_line "失败于 $failed_at；后续 $remain 步未执行"; exit 1
fi
msg="全部 ${#SEQ[@]} 步 healthy"
(( JSON )) || echo "✓ $msg"
log_line "$msg"
exit 0
