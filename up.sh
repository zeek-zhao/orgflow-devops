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
#   up.sh --recreate <svc>      配置指纹变更时安全重建单个服务（5s 确认+健康等待）
#   up.sh <svc>                 兼容旧写法 = --only <svc>
#   DRY_RUN=1 / FORCE_PULL=1 / JSON=1 / FP_STRICT=1 环境变量同样生效
# T3 配置指纹：compose+env+镜像 的 sha256 写入容器 label org.of.fp；
#   指纹 stale 时默认只提示（零停机），FP_STRICT=1 才自动 force-recreate；
#   --recreate <svc> 显式重建（文档验收链路，失败只打印回滚命令不自动回滚）。
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"
# 独立命名空间测试可覆盖：ENV_FILE 指向 v2 env，CONTAINER_PREFIX=ofv2 让 cid/健康探测匹配。
# 默认值保持线上不变（config/defaults.env / of-*），对现有部署零影响。
ENVFILE="${ENV_FILE:-config/defaults.env}"
# T10：本地构建镜像模式（config/images.env）默认关闭；仅 USE_LOCAL_IMAGES=1 时并入 DC。
# 默认路径仍只读 defaults.env，compose 回退已验证 GHCR digest → 零停机、不依赖本地是否构建过。
IMAGES_ENV="${IMAGES_ENV:-config/images.env}"
USE_LOCAL_IMAGES="${USE_LOCAL_IMAGES:-0}"
PREFIX="${CONTAINER_PREFIX:-of}"

# M1 T9.1：Jenkins SSH 密钥不在 .env（安全基线），重建/单起时自动从 secrets/ 注入，
# 避免 JCasC 拿到空私钥导致 agent 节点脱机。已有 env 值（显式 export）优先，不覆盖。
if [[ -z "${JENKINS_AGENT_SSH_KEY:-}" && -s secrets/agent_ssh_key ]]; then
  export JENKINS_AGENT_SSH_KEY="$(cat secrets/agent_ssh_key)"
fi
if [[ -z "${JENKINS_AGENT_HOST_KEY:-}" && -s secrets/agent_host_key.pub ]]; then
  export JENKINS_AGENT_HOST_KEY="$(awk '{print $1" "$2}' secrets/agent_host_key.pub)"
fi

# ---- 读 manifest（顺序 + 依赖 + 健康地址）----
declare -a ORDER=()
declare -A DEPS=() HEALTHURL=()
while IFS=$'\t' read -r order svc deps health monitor ping path tags kind; do
  [[ "$svc" == "service" || -z "$svc" ]] && continue
  ORDER+=("$svc"); DEPS["$svc"]="$deps"; HEALTHURL["$svc"]="$health"
done < <(python3.11 -c "import csv; [print('\t'.join([r['order'],r['service'],r['depends_on'],r['health_url'],r['monitor_url'],r['ping_url'],r['public_path'],r['tags'],r['ui_kind']])) for r in csv.DictReader(open('services/manifest.tsv',encoding='utf-8-sig'),delimiter='\t')]")

# project 名：默认 per-service（独立命名空间测试隔离）；
# 接管存量整栈容器（如线上 orgflow-minimal project）时设 COMPOSE_PROJECT=orgflow-minimal，
# 否则 --recreate 因 container_name 归属不同 project 而静默失败（T8 上线窗口实测发现）。
svc_project() { echo "${COMPOSE_PROJECT:-orgflow-$1}"; }
svc_compose() { echo "services/$1/compose.yml"; }
# T10：USE_LOCAL_IMAGES=1 时把 images.env 放最后（后者覆盖前者）注入本地镜像名。
DC() {
  local extra=()
  [[ "$USE_LOCAL_IMAGES" == "1" ]] && extra=(--env-file "$IMAGES_ENV")
  docker compose --env-file "$ENVFILE" "${extra[@]}" -p "$(svc_project "$1")" -f "$(svc_compose "$1")"
}

# T10：解析默认（GHCR）镜像名，用于 dry-run 展示回退目标
DC_GHCR() { docker compose --env-file "$ENVFILE" -p "$(svc_project "$1")" -f "$(svc_compose "$1")" config 2>/dev/null | awk '/^[[:space:]]+image:/{gsub(/^[[:space:]]+image:[[:space:]]*/,""); print; exit}'; }

# T10：本地镜像模式前置校验——lock 有 PENDING-BUILD 或镜像缺失 ⇒ 告警并回退默认 GHCR。
# 绝不静默指向不存在的 tag 导致容器起不来。返回 0=可安全用本地镜像，1=必须回退。
local_images_ready() {
  local target="${1:-}"
  [[ "$USE_LOCAL_IMAGES" == "1" ]] || return 1
  # lock 门禁：tag 一致性 + PENDING-BUILD 判定（T10/T11 共用 check-images.sh lock）
  if ! bash scripts/check-images.sh --mode=lock >/dev/null 2>&1; then
    echo "  [warn] check-images.sh lock 未通过（PENDING-BUILD/tag 不一致）→ 回退默认 GHCR 镜像" >&2
    return 1
  fi
  # 目标服务的 lock imageId 必须非 PENDING、且本地镜像真实存在
  local img iid
  img="$(grep -E "^IMAGE_$(echo "$target"|tr 'a-z-' 'A-Z_')=" "$IMAGES_ENV" 2>/dev/null | head -1 | cut -d= -f2-)"
  iid="$(awk -F'\t' -v s="$target" '$1==s{print $3}' tests/images.lock 2>/dev/null)"
  [[ -n "$img" && "$iid" != "PENDING-BUILD" && -n "$iid" ]] || {
    echo "  [warn] $target 的 lock imageId=PENDING-BUILD 或缺失 → 回退默认 GHCR 镜像" >&2
    return 1
  }
  if ! docker image inspect "$img" >/dev/null 2>&1; then
    echo "  [warn] 本地镜像 $img 不存在 → 回退默认 GHCR 镜像" >&2
    return 1
  fi
  return 0
}

# ---- 资源真源（defaults.env 注入，带 orgflow-minimal_ 前缀 = §2.5 第0步真实名）----
NET="$(grep -E '^ORG_NETWORK=' "$ENVFILE" | cut -d= -f2-)"
V_CA="$(grep -E '^CA_DATA_VOLUME=' "$ENVFILE" | cut -d= -f2-)"
V_LDAPD="$(grep -E '^LDAP_DATA_VOLUME=' "$ENVFILE" | cut -d= -f2-)"
V_LDAPC="$(grep -E '^LDAP_CONFIG_VOLUME=' "$ENVFILE" | cut -d= -f2-)"
# M1：Jenkins home 卷（若 env 未定义则留空，下面循环跳过空值，向后兼容 M0）
V_JENKINS="$(grep -E '^JENKINS_HOME_VOLUME=' "$ENVFILE" | cut -d= -f2-)"
SUBNET="$(grep -E '^NET_SUBNET=' "$ENVFILE" | cut -d= -f2-)"

# ---- 参数 ----
MODE="full"; FROM=""; TARGET=""
DRY=0; FORCE=0; PULL=1; RECREATE=0
JSON="${JSON:-0}"
FP_STRICT="${FP_STRICT:-0}"
[[ "${DRY_RUN:-0}" == "1" ]] && DRY=1
[[ "${FORCE_PULL:-0}" == "1" ]] && FORCE=1
while (( $# )); do
  case "$1" in
    --json) JSON=1; shift ;;
    --from) FROM="${2:-}"; MODE="from"; shift 2 ;;
    --only) TARGET="${2:-}"; MODE="single"; shift 2 ;;
    --recreate) TARGET="${2:-}"; MODE="single"; RECREATE=1; FORCE=1; shift 2 ;;
    --no-pull) PULL=0; shift ;;
    --dry-run) DRY=1; shift ;;
    -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
    -*) echo "未知参数: $1" >&2; exit 2 ;;
    *) TARGET="$1"; MODE="single"; shift ;;
  esac
done
start_ts=$(date +%s)

# M1 T9.1：实起 jenkins（非 dry-run）时缺密钥直接拦，避免 JCasC 空私钥让节点脱机。
if (( ! DRY )) && [[ "$TARGET" == "jenkins" && ( -z "${JENKINS_AGENT_SSH_KEY:-}" || -z "${JENKINS_AGENT_HOST_KEY:-}" ) ]]; then
  echo "✗ 起 jenkins 缺 SSH 密钥：先跑 scripts/gen-jenkins-secrets.sh 生成 secrets/（见 docs/services/jenkins.md）" >&2
  exit 2
fi

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

# ---- T3 配置指纹：compose + env + 镜像ID 的 sha256 ----
fingerprint() {
  local svc="$1" img iid
  img="$(img_of "$svc")"
  # 镜像 ID：优先本地已存在镜像；不存在则用镜像名占位（指纹仍随 env/compose 变化）
  iid="$(docker image inspect "${img:-none}" --format '{{.Id}}' 2>/dev/null || echo "${img:-none}")"
  # T10：images.env 纳入指纹输入——切本地/GHCR 模式后指纹变化可见（USE_LOCAL_IMAGES 影响实际镜像）
  { cat "services/$svc/compose.yml" "$ENVFILE" "$IMAGES_ENV" 2>/dev/null
    echo "IMAGE=$img"; echo "IID=$iid"; echo "USE_LOCAL_IMAGES=$USE_LOCAL_IMAGES"; } 2>/dev/null | sha256sum | awk '{print $1}'
}
container_fp() {
  local cid; cid="$(svc_cid "$1")"
  [[ -n "$cid" ]] || { echo ""; return; }
  docker inspect -f '{{index .Config.Labels "org.of.fp"}}' "$cid" 2>/dev/null | grep -v '^<no value>$' || true
}
fp_status() {
  local svc="$1" want have cid
  cid="$(svc_cid "$svc")"
  [[ -n "$cid" ]] || { echo "absent"; return; }
  want="$(fingerprint "$svc")"; have="$(container_fp "$svc")"
  [[ -z "$have" ]] && { echo "baseline"; return; }   # 无 label：线上存量容器，不自动重建
  [[ "$have" == "$want" ]] && echo "match" || echo "stale"
}

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
  for v in "$V_CA" "$V_LDAPD" "$V_LDAPC" "$V_JENKINS"; do
    [[ -z "$v" ]] && continue
    if docker volume inspect "$v" >/dev/null 2>&1; then
      res_note "卷 $v 已存在，跳过"
    else
      (( DRY )) && { res_note "[dry] 将建卷 $v"; continue; }
      docker volume create "$v" >/dev/null
      res_note "✓ 建卷 $v"
    fi
  done
}

svc_cid() { docker ps -aq -f "name=^${PREFIX}-$1\$" 2>/dev/null | head -1; }
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
  local svc="$1" t0 t1 cid healthy="—" img note="" fp
  if ! dep_ready "$svc"; then note="(依赖未就绪，跳过依赖仅起本体)"; fi
  # dry-run 优先：无论是否已健康，都只演不跑（§8.3 要 dry-run 输出 manifest 顺序）
  if (( DRY )); then
    # T10：解析实际会选用的镜像（本地模式就绪→本地名，否则 GHCR 回退），便于验收
    local dry_img
    if [[ "$USE_LOCAL_IMAGES" == "1" ]] && local_images_ready "$svc"; then
      dry_img="$(img_of "$svc")"
    else
      dry_img="$(DC_GHCR "$svc")"
    fi
    emit "$svc" "dry" "$dry_img" 0 "" "—" "只演不跑 $note"; return 0
  fi
  if svc_healthy "$svc" && (( ! FORCE )); then
    # T3：指纹 stale 时默认只提示（零停机）；FP_STRICT=1 才自动重建
    local fps; fps="$(fp_status "$svc")"
    if [[ "$fps" == "stale" ]]; then
      note="$note (配置指纹 stale)"
      if [[ "$FP_STRICT" == "1" ]]; then
        note="$note → FP_STRICT 自动重建"
        FORCE=1
      fi
    fi
    if (( ! FORCE )); then
      cid="$(svc_cid "$svc")"; emit "$svc" "skip" "$(img_of "$svc")" 0 "$cid" "healthy" "skip (already healthy) $note"; return 0
    fi
  fi
  # T10：本地镜像模式前置校验——依赖未就绪则本次降级为默认 GHCR（避免起不来）。
  # 用局部覆盖 USE_LOCAL_IMAGES，仅作用于本服务本次启动，不改全局/其它服务。
  local saved_local="$USE_LOCAL_IMAGES"
  if [[ "$USE_LOCAL_IMAGES" == "1" ]] && ! local_images_ready "$svc"; then
    USE_LOCAL_IMAGES=0
  fi
  fp="$(fingerprint "$svc")"
  t0=$(date +%s%3N)
  if (( PULL )) && [[ "$USE_LOCAL_IMAGES" != "1" ]]; then DC "$svc" pull >/dev/null 2>&1; fi
  # --recreate/FP_STRICT 重建才加 --force-recreate；普通 up 对不健康容器只 up -d（不改线上健康容器）
  if (( FORCE )); then
    FP_VALUE="$fp" DC "$svc" up -d --no-deps --force-recreate "$svc" >/dev/null 2>&1
  else
    FP_VALUE="$fp" DC "$svc" up -d --no-deps "$svc" >/dev/null 2>&1
  fi
  t1=$(date +%s%3N)
  # 等容器名出现（compose 创建有微小延迟；一次性容器可能已 Exited，用 -aq 查）
  for _ in 1 2 3 4 5; do cid="$(svc_cid "$svc")"; [[ -n "$cid" ]] && break; sleep 1; done
  if wait_healthy "$svc"; then healthy="healthy"; else healthy="UNHEALTHY"; fi
  [[ -n "$cid" ]] || cid="$(svc_cid "$svc")"
  USE_LOCAL_IMAGES="$saved_local"  # T10：恢复全局开关，降级只作用于本服务本次启动
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

# --recreate：打印回滚命令 + 5 秒确认窗口（非交互用 sleep，Ctrl-C 可取消）
if (( RECREATE )); then
  old_cid="$(svc_cid "$TARGET")"
  old_img="$(docker inspect -f '{{.Image}}' "$old_cid" 2>/dev/null || echo '(无)')"
  old_id="${old_img#sha256:}"
  echo "⚠ 即将重建 $TARGET（单服务，不影响其它容器）" >&2
  echo "  回滚命令：docker run -d --name ${PREFIX}-${TARGET} ... （旧镜像 ${old_id:0:19}）；或 git revert 后 bash up.sh --recreate $TARGET" >&2
  echo "  5 秒内可 Ctrl-C 取消…" >&2
  sleep 5
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
  (( RECREATE )) && echo "  回滚：用旧 imageId 重建 $failed_at；或 git revert 后重试（不自动回滚）" >&2
  log_line "失败于 $failed_at；后续 $remain 步未执行"; exit 1
fi
msg="全部 ${#SEQ[@]} 步 healthy"
(( JSON )) || echo "✓ $msg"
log_line "$msg"
exit 0
