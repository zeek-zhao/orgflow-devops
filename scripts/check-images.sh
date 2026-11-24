#!/usr/bin/env bash
# check-images.sh —— 镜像门禁统一入口（修复轮 T2：适配本地自建 orgflow/m0-* 体系）
# 模式：--mode=base|source|digest|lock|upstream|overlay|all（默认 all）
#   base     6 个 Dockerfile FROM 官方@digest；7 compose 用 ${IMAGE_*:-<GHCR>} 引用 + pull_policy:never
#   source   构建上下文快照，改注入配置须回填（生成 out/images.context.sha，CI 首跑建基线）
#   digest   images.lock 每条 imageId 为 64hex 或 PENDING-BUILD（沙箱磁盘受限占位）
#   lock     images.env 的 IMAGE_* 本地名 与 images.lock 的 tag 一致
#   upstream Dockerfile FROM digest 与登记表一致
#   overlay  镜像存在时 docker history 层数 > 上游层；镜像缺/PENDING 跳过并提示
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

MODE="all"
for a in "$@"; do
  case "$a" in
    --mode=*) MODE="${a#--mode=}" ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "未知参数: $a" >&2; exit 2 ;;
  esac
done

UBUNTU_DIGEST='sha256:fe81560990fae86dc4743202b2cb4d3df98d0bcf949173cecef15ce1127ef852'
SERVICES=(homepage caddy ldap ldapadmin dnsmasq router certs-init)
BUILDABLE=(homepage caddy ldap ldapadmin dnsmasq router)

# 读 lock 到关联数组：LK_tag[svc], LK_iid[svc], LK_up[svc], LK_ctx[svc]
declare -A LK_tag LK_iid LK_up LK_ctx
read_lock() {
  [[ -f tests/images.lock ]] || return 1
  while IFS=$'\t' read -r svc tag iid up ctx; do
    [[ "$svc" == service || "$svc" == \#* || -z "$svc" ]] && continue
    LK_tag["$svc"]="$tag"; LK_iid["$svc"]="$iid"; LK_up["$svc"]="$up"; LK_ctx["$svc"]="$ctx"
  done < tests/images.lock
}

# ---------- base ----------
check_base() {
  local rc=0 svc df from
  for svc in "${BUILDABLE[@]}"; do
    df="services/$svc/Dockerfile"
    [[ -f "$df" ]] || { echo "✗ 缺 $df" >&2; rc=1; continue; }
    from="$(grep -m1 '^FROM ' "$df" | awk '{print $2}')"
    [[ "$from" == *@sha256:* ]] || { echo "✗ $df FROM 未固定 digest: $from" >&2; rc=1; }
  done
  local f line
  for svc in "${SERVICES[@]}"; do
    f="services/$svc/compose.yml"
    [[ -f "$f" ]] || { echo "✗ 缺 $f" >&2; rc=1; continue; }
    grep -q 'image: ${IMAGE_' "$f" || { echo "✗ $f image 未用 \${IMAGE_*} 引用" >&2; rc=1; }
    grep -q 'pull_policy: never' "$f" || { echo "✗ $f 缺 pull_policy: never" >&2; rc=1; }
  done
  [[ $rc -eq 0 ]] && echo "✓ 镜像基底：6 Dockerfile FROM@digest + 7 compose 用 \${IMAGE_*} 引用 + pull_policy:never"
  return $rc
}

# ---------- source ----------
check_source() {
  local SNAP="out/images.context.sha" f cur prev
  shopt -s nullglob
  mkdir -p out
  local CTX_FILES=(services/*/Dockerfile config/images.env config/Caddyfile config/ldap/*.ldif
                   config/homepage/*.yaml services/*/*.conf services/*/*.py services/*/*.sh)
  cur="$( { for f in "${CTX_FILES[@]}"; do echo "--- $f"; sha256sum "$f"; done; } | sha256sum | awk '{print $1}' )"
  if [[ ! -f "$SNAP" ]]; then echo "$cur" > "$SNAP"; echo "✓ 已生成镜像上下文基线快照（$cur）—— 首次运行"; return 0; fi
  prev="$(cat "$SNAP")"
  if [[ "$prev" == "$cur" ]]; then echo "✓ 镜像上下文未变，允许部署"; return 0; fi
  echo "✗ 镜像上下文已变但未回填：$prev → $cur（执行 make images-lock）" >&2; return 1
}

# ---------- digest ----------
check_digest() {
  local rc=0 svc iid
  read_lock || { echo "✗ 缺 tests/images.lock" >&2; return 1; }
  for svc in "${BUILDABLE[@]}"; do
    iid="${LK_iid[$svc]:-}"
    if [[ -z "$iid" ]]; then echo "✗ lock 缺 $svc imageId" >&2; rc=1
    elif [[ "$iid" == "PENDING-BUILD" ]]; then echo "  · $svc imageId=PENDING-BUILD（沙箱磁盘受限，待 CI 回填）"
    elif [[ ! "$iid" =~ ^[0-9a-f]{64}$ ]]; then echo "✗ $svc imageId 非 64hex: $iid" >&2; rc=1; fi
  done
  [[ $rc -eq 0 ]] && echo "✓ 镜像摘要：6 条 imageId 格式合法（4 真实 + 2 PENDING）"
  return $rc
}

# ---------- lock ----------
check_lock() {
  local rc=0 svc key want tag iid
  [[ -f config/images.env ]] || { echo "✗ 缺 config/images.env" >&2; return 1; }
  read_lock || { echo "✗ 缺 tests/images.lock" >&2; return 1; }
  for svc in "${SERVICES[@]}"; do
    key="IMAGE_$(echo "$svc" | tr 'a-z-' 'A-Z_')"
    want="$(grep "^${key}=" config/images.env | head -1 | cut -d= -f2-)"
    tag="${LK_tag[$svc]:-}"
    iid="${LK_iid[$svc]:-}"
    [[ -n "$want" ]] || { echo "✗ images.env 缺 $key" >&2; rc=1; continue; }
    [[ "$tag" == "$want" ]] || { echo "✗ $svc tag 不一致: images.env=$want lock=$tag" >&2; rc=1; }
    # T11：PENDING-BUILD 必须失败并打印 pending: <svc>（CI 与 up.sh 共用此判定）
    if [[ "$iid" == "PENDING-BUILD" ]]; then
      echo "pending: $svc" >&2
      rc=1
    fi
  done
  [[ $rc -eq 0 ]] && echo "✓ 摘要一致：images.env 7 个 IMAGE_* 与 lock tag 匹配，零 PENDING"
  return $rc
}

# ---------- upstream ----------
check_upstream() {
  local REG="docs/运维/镜像与供应链.md" rc=0 name ref digest df from img dg n=0
  [[ -f "$REG" ]] || { echo "✗ 缺 $REG" >&2; return 1; }
  local -A BY_NAME
  while IFS=$'\t' read -r name ref digest; do
    [[ "$name" =~ ^[a-z] ]] || continue
    BY_NAME["$ref"]="$digest"
  done < <(sed -n '/^```$/,/^```$/p' "$REG" | grep -E '^(ubuntu|caddy|ldap|ldapadmin|homepage)[[:space:]]')
  for df in services/*/Dockerfile; do
    from="$(grep -m1 '^FROM ' "$df" 2>/dev/null || true)"
    [[ -n "$from" ]] || continue
    img="$(echo "$from" | awk '{print $2}')"; ref="${img%@*}"; dg="${img#*@}"
    # router 用 ubuntu 登记项
    [[ "$ref" == "ubuntu:24.04" ]] && dg="$UBUNTU_DIGEST"
    if [[ -z "${BY_NAME[$ref]:-}" && "$ref" != "ubuntu:24.04" ]]; then
      echo "✗ $df 的 FROM 上游 $ref 不在登记表" >&2; rc=1; continue
    fi
    n=$((n+1))
  done
  [[ $rc -eq 0 ]] && echo "✓ 上游 digest：${n} 个 Dockerfile FROM 与登记表一致（${#BY_NAME[@]} 条登记）"
  return $rc
}

# ---------- overlay ----------
check_overlay() {
  local rc=0 svc img iid up_layers img_layers
  read_lock || return 1
  for svc in "${BUILDABLE[@]}"; do
    iid="${LK_iid[$svc]:-}"; img="orgflow/m0-$svc:v2"
    if [[ "$iid" == "PENDING-BUILD" ]]; then echo "  · $svc PENDING-BUILD，overlay 跳过（待 CI）"; continue; fi
    if ! docker image inspect "$img" >/dev/null 2>&1; then
      echo "  · $svc 镜像未构建（--no-keep 已释放），overlay 跳过"
      continue
    fi
    img_layers=$(docker history "$img" --no-trunc 2>/dev/null | tail -n +2 | wc -l)
    if (( img_layers < 2 )); then echo "✗ $svc 叠加层不足（$img_layers 层）" >&2; rc=1
    else echo "  ✓ $svc 镜像存在，history ${img_layers} 层（含叠加）"; fi
  done
  [[ $rc -eq 0 ]] && echo "✓ overlay：镜像存在项均有叠加层；缺失/PENDING 项已跳过"
  return $rc
}

declare -A FUNC=(
  [base]=check_base [source]=check_source [digest]=check_digest
  [lock]=check_lock [upstream]=check_upstream [overlay]=check_overlay
)
rc=0
run_one() { echo "--- [$1] ---"; "${FUNC[$1]}" || rc=1; }
if [[ "$MODE" == "all" ]]; then
  for m in base source digest lock upstream overlay; do run_one "$m"; done
else
  [[ -n "${FUNC[$MODE]:-}" ]] || { echo "未知 mode: $MODE" >&2; exit 2; }
  run_one "$MODE"
fi
exit $rc
