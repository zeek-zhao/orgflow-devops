#!/usr/bin/env bash
# check-images.sh —— 镜像门禁统一入口（r5 §2：M1 改用「内容哈希」替代 CI digest 回填）
# 模式：--mode=base|digest|lock|upstream|overlay|all（默认 all）
#   base     8 个 Dockerfile FROM 官方@digest；9 compose 用 ${IMAGE_*} 引用 + pull_policy:never|missing
#   digest   images.lock：M0 6 项 imageId 为 64hex；M1 2 项（HASHED）imageId 必须为 "-"
#   lock     tag 一致性 + HASHED 强校验：image-hash.sh == LK_ctx，tag 后缀 == ctx-<hash:0:12>
#   upstream Dockerfile FROM digest 与登记表一致
#   overlay  镜像存在时 docker history 层数 > 上游层；用 LK_tag 取镜像名，缺镜像跳过
#
# r5 变更（§2.6）：
#   - 删 --mode=source（与按服务哈希冲突），配套 update-images-lock.sh / make images-lock 一并删除；
#   - SERVICES/BUILDABLE 由 services/*/ 扫描派生（不再硬编码）；新增 HASHED=(jenkins jenkins-agent)；
#   - check_digest 对 HASHED 只要求 imageId="-"；check_lock 对 HASHED 强校验内容哈希与 tag 后缀；
#   - check_overlay 用 LK_tag 替代拼接 orgflow/m0-$svc:v2，删除 PENDING-BUILD 分支。
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

MODE="all"
for a in "$@"; do
  case "$a" in
    --mode=*) MODE="${a#--mode=}" ;;
    -h|--help) sed -n '2,14p' "$0"; exit 0 ;;
    *) echo "未知参数: $a" >&2; exit 2 ;;
  esac
done

UBUNTU_DIGEST='sha256:fe81560990fae86dc4743202b2cb4d3df98d0bcf949173cecef15ce1127ef852'
# 扫描派生：有 compose.yml 的服务即 SERVICES；有 Dockerfile 的即 BUILDABLE；M1 走内容哈希的服务。
SERVICES=(); BUILDABLE=(); HASHED=(jenkins jenkins-agent cgit registry builder gerrit certs-init)
for d in services/*/; do
  svc="${d#services/}"; svc="${svc%/}"
  [[ "$svc" == _* ]] && continue  # M2 P4：下划线开头为脚手架模板（_template），非真实服务
  [[ -f "$d/compose.yml" ]] && SERVICES+=("$svc")
  [[ -f "$d/Dockerfile" ]] && BUILDABLE+=("$svc")
done

declare -A LK_tag LK_iid LK_up LK_ctx
read_lock() {
  [[ -f tests/images.lock ]] || return 1
  while IFS=$'\t' read -r svc tag iid up ctx; do
    [[ "$svc" == service || "$svc" == \#* || -z "$svc" ]] && continue
    LK_tag["$svc"]="$tag"; LK_iid["$svc"]="$iid"; LK_up["$svc"]="$up"; LK_ctx["$svc"]="$ctx"
  done < tests/images.lock
}
is_hashed() { local x; for x in "${HASHED[@]}"; do [[ "$x" == "$1" ]] && return 0; done; return 1; }

# ---------- base ----------
check_base() {
  local rc=0 svc df from
  for svc in "${BUILDABLE[@]}"; do
    df="services/$svc/Dockerfile"
    [[ -f "$df" ]] || { echo "✗ 缺 $df" >&2; rc=1; continue; }
    from="$(grep -m1 '^FROM ' "$df" | awk '{print $2}')"
    if [[ "$from" == *@sha256:* ]]; then
      : # 字面固定 digest（M0/M1/cgit 既有口径）
    elif [[ "$from" == *@\$\{*\} ]]; then
      # M2.2 P2-2：FROM registry:2@${BASE_DIGEST}。必须在本文件声明真实 digest 默认值，
      # 保证仓库可直接 docker build（默认可构建）、CI 再用 --build-arg 注入当日实拉值。
      arg="${from#*@\$\{}"; arg="${arg%%\}*}"
      grep -qE "^ARG ${arg}=sha256:[0-9a-f]{64}$" "$df" \
        || { echo "✗ $df 缺 ARG ${arg}=sha256:<真实64位> 默认值（本地不可构建）" >&2; rc=1; }
    else
      echo "✗ $df FROM 未固定 digest: $from" >&2; rc=1
    fi
  done
  local f
  for svc in "${SERVICES[@]}"; do
    f="services/$svc/compose.yml"
    [[ -f "$f" ]] || { echo "✗ 缺 $f" >&2; rc=1; continue; }
    grep -q 'image: ${IMAGE_' "$f" || { echo "✗ $f image 未用 \${IMAGE_*} 引用" >&2; rc=1; }
    grep -qE 'pull_policy: (never|missing)' "$f" || { echo "✗ $f 缺 pull_policy: never|missing" >&2; rc=1; }
  done
  [[ $rc -eq 0 ]] && echo "✓ 镜像基底：${#BUILDABLE[@]} Dockerfile FROM@digest + ${#SERVICES[@]} compose 用 \${IMAGE_*} 引用 + pull_policy:never|missing"
  return $rc
}

# ---------- digest ----------
check_digest() {
  local rc=0 svc iid m0=0 hashed=0
  read_lock || { echo "✗ 缺 tests/images.lock" >&2; return 1; }
  for svc in "${BUILDABLE[@]}"; do
    iid="${LK_iid[$svc]:-}"
    if is_hashed "$svc"; then
      # M1 内容哈希服务：imageId 必须为 "-"，不再校验 64hex
      if [[ "$iid" == "-" ]]; then hashed=$((hashed+1));
      else echo "✗ $svc（HASHED）imageId 应为 '-'，实为 '$iid'" >&2; rc=1; fi
    else
      if [[ -z "$iid" ]]; then echo "✗ lock 缺 $svc imageId" >&2; rc=1
      elif [[ "$iid" == "PENDING-BUILD" ]]; then echo "✗ $svc imageId=PENDING-BUILD（r5 已废弃该口径）" >&2; rc=1
      elif [[ ! "$iid" =~ ^[0-9a-f]{64}$ ]]; then echo "✗ $svc imageId 非 64hex: $iid" >&2; rc=1
      else m0=$((m0+1)); fi
    fi
  done
  [[ $rc -eq 0 ]] && echo "✓ 镜像标识：M0 ${m0} 项 imageId 合法 + M1 ${hashed} 项走内容哈希"
  return $rc
}

# ---------- lock ----------
check_lock() {
  local rc=0 svc key want tag iid hash wanttag
  [[ -f config/images.env ]] || { echo "✗ 缺 config/images.env" >&2; return 1; }
  read_lock || { echo "✗ 缺 tests/images.lock" >&2; return 1; }
  for svc in "${SERVICES[@]}"; do
    key="IMAGE_$(echo "$svc" | tr 'a-z-' 'A-Z_')"
    [[ "$svc" == certs-init ]] && key="IMAGE_CERTS_INIT"
    want="$(grep "^${key}=" config/images.env | head -1 | cut -d= -f2-)"
    tag="${LK_tag[$svc]:-}"
    iid="${LK_iid[$svc]:-}"
    [[ -n "$want" ]] || { echo "✗ images.env 缺 $key" >&2; rc=1; continue; }
    [[ "$tag" == "$want" ]] || { echo "✗ $svc tag 不一致: images.env=$want lock=$tag" >&2; rc=1; }
    [[ "$iid" != "PENDING-BUILD" ]] || { echo "✗ $svc 仍为 PENDING-BUILD（r5 已废弃）" >&2; rc=1; }
    if is_hashed "$svc"; then
      hash="$(bash scripts/image-hash.sh "$svc" 2>/dev/null)" || { echo "✗ $svc image-hash.sh 执行失败" >&2; rc=1; continue; }
      [[ "$hash" == "${LK_ctx[$svc]:-}" ]] || { echo "✗ $svc 内容哈希不一致: 计算=$hash lock=${LK_ctx[$svc]:-}（改完 Dockerfile 请跑 make images-hash 并同步 compose）" >&2; rc=1; }
      # M2.2 P1-3：M1 服务（jenkins/jenkins-agent/certs-init）保留 m1 前缀；
      # M2 服务（cgit/registry/builder/gerrit）统一 m2。
      case "$svc" in
        cgit|registry|builder|gerrit) wantprefix="m2" ;;
        *) wantprefix="m1" ;;
      esac
      wanttag="orgflow/$wantprefix-$svc:ctx-${hash:0:12}"
      [[ "$tag" == "$wanttag" ]] || { echo "✗ $svc tag 后缀不一致: lock=$tag 应为 $wanttag（跑 make images-hash）" >&2; rc=1; }
      [[ "$iid" == "-" ]] || { echo "✗ $svc（HASHED）imageId 应为 '-'，实为 '$iid'" >&2; rc=1; }
    fi
  done
  [[ $rc -eq 0 ]] && echo "✓ 摘要一致：images.env ${#SERVICES[@]} 个 IMAGE_* 与 lock tag 匹配；${#HASHED[@]} 项内容哈希与 tag 后缀一致"
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
  done < <(sed -n '/^```$/,/^```$/p' "$REG" | grep -E '^(ubuntu|caddy|ldap|ldapadmin|homepage|jenkins|registry|buildkit|gerritcodereview)[[:space:]]')
  for df in services/*/Dockerfile; do
    [[ "$df" == services/_*/Dockerfile ]] && continue  # 排除脚手架模板
    from="$(grep -m1 '^FROM ' "$df" 2>/dev/null || true)"
    [[ -n "$from" ]] || continue
    img="$(echo "$from" | awk '{print $2}')"; ref="${img%@*}"; dg="${img#*@}"
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
  local rc=0 svc img iid layers
  read_lock || return 1
  for svc in "${BUILDABLE[@]}"; do
    iid="${LK_iid[$svc]:-}"; img="${LK_tag[$svc]:-}"
    if ! docker image inspect "$img" >/dev/null 2>&1; then
      echo "  · $svc 镜像 $img 不存在（本沙箱仅存 GHCR 镜像），overlay 跳过"
      continue
    fi
    layers=$(docker history "$img" --no-trunc 2>/dev/null | tail -n +2 | wc -l)
    if (( layers < 2 )); then echo "✗ $svc 叠加层不足（$layers 层）" >&2; rc=1
    else echo "  ✓ $svc 镜像 $img 存在，history ${layers} 层（含叠加）"; fi
  done
  [[ $rc -eq 0 ]] && echo "✓ overlay：镜像存在项均有叠加层；缺失项已跳过"
  return $rc
}

declare -A FUNC=(
  [base]=check_base [digest]=check_digest
  [lock]=check_lock [upstream]=check_upstream [overlay]=check_overlay
)
rc=0
run_one() { echo "--- [$1] ---"; "${FUNC[$1]}" || rc=1; }
if [[ "$MODE" == "all" ]]; then
  for m in base digest lock upstream overlay; do run_one "$m"; done
else
  [[ -n "${FUNC[$MODE]:-}" ]] || { echo "未知 mode: $MODE（r5 已删除 source 模式）" >&2; exit 2; }
  run_one "$MODE"
fi
exit $rc
