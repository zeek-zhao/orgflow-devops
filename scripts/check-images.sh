#!/usr/bin/env bash
# check-images.sh —— 镜像门禁统一入口（M0-v2 R4 合并）
# 由 5 个旧脚本合并而来，判定逻辑原样保留，只换入口：
#   --mode=base|source|digest|lock|upstream|all（默认 all）
# 旧脚本 check-base-image / check-image-source / check-image-digest /
# check-images-lock / check-upstream-digest 已删除，调用方一律走本入口。
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

MODE="all"
for a in "$@"; do
  case "$a" in
    --mode=*) MODE="${a#--mode=}" ;;
    -h|--help) echo "用法: check-images.sh --mode=base|source|digest|lock|upstream|all"; exit 0 ;;
    *) echo "未知参数: $a" >&2; exit 2 ;;
  esac
done

UBUNTU_DIGEST='sha256:fe81560990fae86dc4743202b2cb4d3df98d0bcf949173cecef15ce1127ef852'

# ---------- base: 自建基底 + 本仓 GHCR 源（原 check-base-image.sh） ----------
check_base() {
  local rc=0 f line img
  shopt -s nullglob
  local svc df from
  for svc in dnsmasq router; do
    df="services/$svc/Dockerfile"
    if [[ ! -f "$df" ]]; then echo "✗ 缺自建镜像 Dockerfile: $df" >&2; rc=1; continue; fi
    from="$(grep -m1 '^FROM ' "$df" | awk '{print $2}')"
    if [[ "$from" != "ubuntu:24.04@$UBUNTU_DIGEST" ]]; then
      echo "✗ $df 基底应为 ubuntu:24.04@${UBUNTU_DIGEST:0:19}…，实为 $from" >&2; rc=1
    fi
  done
  local composes=(docker-compose.yml services/*/compose.yml)
  local src_re='zeek-zhao/orgflow-devops/'
  for f in "${composes[@]}"; do
    [[ -f "$f" ]] || continue
    while IFS= read -r line; do
      [[ "$line" =~ ^[[:space:]]*-?[[:space:]]*image:[[:space:]]* ]] || continue
      img="$(echo "$line" | sed -E 's/^[[:space:]]*-?[[:space:]]*image:[[:space:]]*//; s/[[:space:]]+$//')"
      [[ "$img" == *"$src_re"* ]] || { echo "✗ $f 镜像非本仓 GHCR 源: $img" >&2; rc=1; }
    done < "$f"
  done
  [[ $rc -eq 0 ]] && echo "✓ 镜像基底统一：2 自建(ubuntu@digest) + 4 薄封装(登记表) + compose 全来自本仓 GHCR"
  return $rc
}

# ---------- source: 上下文快照，改注入配置须回填（原 check-image-source.sh） ----------
check_source() {
  shopt -s nullglob
  local SNAP="out/images.context.sha"
  mkdir -p out
  local f cur prev
  local CTX_FILES=(services/*/Dockerfile config/images.env config/Caddyfile config/ldap/*.ldif
                   config/homepage/*.yaml services/*/*.conf services/*/*.py services/*/*.sh)
  cur="$( { for f in "${CTX_FILES[@]}"; do echo "--- $f"; sha256sum "$f"; done; } | sha256sum | awk '{print $1}' )"
  if [[ ! -f "$SNAP" ]]; then
    echo "$cur" > "$SNAP"
    echo "✓ 已生成镜像上下文基线快照（$cur）—— 首次运行"
    return 0
  fi
  prev="$(cat "$SNAP")"
  if [[ "$prev" == "$cur" ]]; then
    echo "✓ 镜像上下文未变，允许部署"
    return 0
  fi
  echo "✗ 镜像上下文已变但未回填 digest：$prev → $cur" >&2
  echo "  执行 make images-lock 回填后重试" >&2
  return 1
}

# ---------- digest: 所有 compose image 带 @sha256（原 check-image-digest.sh） ----------
check_digest() {
  local rc=0 f line img c
  shopt -s nullglob
  local files=()
  [[ -f docker-compose.yml ]] && files+=(docker-compose.yml)
  for c in services/*/compose.yml; do [[ -f "$c" ]] && files+=("$c"); done
  if [[ ${#files[@]} -eq 0 ]]; then echo "  - 暂无 compose，跳过"; return 0; fi
  local re='@sha256:[0-9a-f]{64}$'
  for f in "${files[@]}"; do
    while IFS= read -r line; do
      [[ "$line" =~ ^[[:space:]]*-?[[:space:]]*image:[[:space:]]* ]] || continue
      img="$(echo "$line" | sed -E 's/^[[:space:]]*-?[[:space:]]*image:[[:space:]]*//; s/[[:space:]]+$//')"
      if [[ "$img" =~ $re ]]; then :; else
        echo "✗ $f 镜像未锁 digest: $img" >&2; rc=1
      fi
    done < "$f"
  done
  [[ $rc -eq 0 ]] && echo "✓ 镜像摘要：${#files[@]} 个 compose 的 image 全部 @sha256"
  return $rc
}

# ---------- lock: images.env 与 images.lock 一致（原 check-images-lock.sh） ----------
check_lock() {
  local rc=0 k v lk
  [[ -f config/images.env ]] || { echo "✗ 缺 config/images.env" >&2; return 1; }
  [[ -f tests/images.lock ]] || { echo "✗ 缺 tests/images.lock" >&2; return 1; }
  local -A ENV_D LOCK_D
  while IFS='=' read -r k v; do [[ "$k" =~ ^IMAGE_ ]] && ENV_D["${k#IMAGE_}"]="$v"; done < <(grep -vE '^\s*#|^\s*$' config/images.env)
  while IFS='=' read -r k v; do LOCK_D["$k"]="$v"; done < <(grep -vE '^\s*#|^\s*$' tests/images.lock)
  for k in "${!ENV_D[@]}"; do
    lk="$(echo "$k" | tr '[:upper:]' '[:lower:]' | tr '_' '-')"
    if [[ -z "${LOCK_D[$lk]:-}" ]]; then echo "✗ images.lock 缺 $lk" >&2; rc=1
    elif [[ "${LOCK_D[$lk]}" != "${ENV_D[$k]}" ]]; then echo "✗ $lk digest 不一致: images.env=${ENV_D[$k]} lock=${LOCK_D[$lk]}" >&2; rc=1; fi
  done
  [[ $rc -eq 0 ]] && echo "✓ 摘要一致：config/images.env 与 tests/images.lock ${#ENV_D[@]} 项全部匹配"
  return $rc
}

# ---------- upstream: Dockerfile FROM 与登记表一致（原 check-upstream-digest.sh） ----------
check_upstream() {
  local REG="docs/engineering/镜像与供应链.md"
  local rc=0 name ref digest df from img dg
  local n=0
  [[ -f "$REG" ]] || { echo "✗ 缺 $REG" >&2; return 1; }
  local -A REF BY_NAME
  while IFS=$'\t' read -r name ref digest; do
    [[ "$name" =~ ^[a-z] ]] || continue
    REF["$name"]="$ref"
    BY_NAME["$ref"]="$digest"
  done < <(sed -n '/^```$/,/^```$/p' "$REG" | grep -E '^(ubuntu|caddy|ldap|ldapadmin|homepage)[[:space:]]')
  shopt -s nullglob
  for df in services/*/Dockerfile; do
    from="$(grep -m1 '^FROM ' "$df" 2>/dev/null || true)"
    [[ -n "$from" ]] || continue
    img="$(echo "$from" | awk '{print $2}')"
    ref="${img%@*}"
    dg="${img#*@}"
    if [[ -z "${BY_NAME[$ref]:-}" ]]; then
      echo "✗ $df 的 FROM 上游 $ref 不在登记表" >&2; rc=1; continue
    fi
    if [[ "$dg" != "${BY_NAME[$ref]}" ]]; then
      echo "✗ $df 的 FROM digest 与登记表不符: $dg != ${BY_NAME[$ref]}" >&2; rc=1; continue
    fi
    echo "  ✓ $(basename "$(dirname "$df")") FROM $ref@${dg:0:19}…"
    n=$((n+1))
  done
  [[ $rc -eq 0 ]] && echo "✓ 上游 digest：${n} 个 Dockerfile 的 FROM 与登记表一致（${#BY_NAME[@]} 条登记）"
  return $rc
}

declare -A FUNC=(
  [base]=check_base [source]=check_source [digest]=check_digest
  [lock]=check_lock [upstream]=check_upstream
)
rc=0
run_one() {
  local m="$1"
  echo "--- [$m] ---"
  "${FUNC[$m]}" || rc=1
}
if [[ "$MODE" == "all" ]]; then
  for m in base source digest lock upstream; do run_one "$m"; done
else
  [[ -n "${FUNC[$MODE]:-}" ]] || { echo "未知 mode: $MODE" >&2; exit 2; }
  run_one "$MODE"
fi
exit $rc
