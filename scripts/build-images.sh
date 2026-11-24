#!/usr/bin/env bash
# build-images.sh —— 修复轮 T2：6 个镜像在本分支本地真构建（certs-init 复用 router）。
#
# 原则（文档 §3）：
#   - 上游真源用 FROM <官方镜像>@sha256:<digest> 固定（Dockerfile 里保留）；
#   - 离线/国内环境拉不动 DockerHub：构建时把 FROM 的 @sha256 临时替换为本地已 tag 的
#     基础镜像短名（--network=none 全程不联网，digest 由 GHCR 代理产物预置）；
#   - 每个镜像相对上游必须多 ≥1 层（配置/脚本/license 叠加），overlay 由 check-images.sh 校验；
#   - 构建完输出 service/tag/imageId/upstreamDigest/contextSha256 写入 tests/images.lock。
#
# 用法：
#   bash scripts/build-images.sh                    # 构建全部 6 个（默认保留镜像）
#   bash scripts/build-images.sh --only homepage    # 只构建一个
#   bash scripts/build-images.sh --no-cache         # 禁用构建缓存
#   bash scripts/build-images.sh --no-keep          # 构建并记录后删除镜像（沙箱磁盘受限时用）
#   bash scripts/build-images.sh --push             # 有 GHCR 写权限时推送
#   bash scripts/build-images.sh --dry-run          # 只打印计划
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

ONLY=""; NO_CACHE=""; NO_KEEP=0; PUSH=0; DRY=0
for ((i=1;i<=$#;i++)); do
  a="${!i}"
  case "$a" in
    --only=*) ONLY="${a#--only=}" ;;
    --only) j=$((i+1)); ONLY="${!j:-}" ;;
    --no-cache) NO_CACHE="--no-cache" ;;
    --no-keep) NO_KEEP=1 ;;
    --push) PUSH=1 ;;
    --dry-run|--dry) DRY=1 ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
  esac
done

SERVICES=(homepage caddy ldap ldapadmin dnsmasq router)
# 本地基础镜像 tag（由 GHCR 代理产物预打；真源 Dockerfile 保留 @digest）
declare -A BASE_TAG=(
  [homepage]="gethomepage/homepage:v2.7.0"
  [caddy]="caddy:2"
  [ldap]="osixia/openldap:1.5.0"
  [ldapadmin]="osixia/phpldapadmin:0.9.0"
  [dnsmasq]="ghcr.nju.edu.cn/zeek-zhao/orgflow-devops/dnsmasq@sha256:9f1a5959399d1ff65e258a6f2f477c2430f9d9851764dce16b7779579c3d32f6"
  [router]="ghcr.nju.edu.cn/zeek-zhao/orgflow-devops/router@sha256:e5fd71d1cd7cec5068a24ce1165e35587856e2cafe7ca2e772a3b50944f9fe87"
)
declare -A MIRROR_ID=(
  [homepage]="0193309878fc07a9016fc8bb36a54206bc1b1d17226049d7e0250bceef2d4078"
  [caddy]="3067cc4e02c091399edbd5d65f85a3ff4d511574aecadb47f280c3761e68852e"
  [ldap]="2da3cf664891c7393a5a2a1b0a4d7d354f7c63491fae94e0f60a2d66519865e1"
  [ldapadmin]="78148b61fdb5b3a456e35ef10804e00553675d513c7cd12b1b4b7b6c18072ce0"
)

upstream_digest() {
  local key
  case "$1" in
    homepage) key=IMAGE_HOMEPAGE;; caddy) key=IMAGE_CADDY;; ldap) key=IMAGE_LDAP;;
    ldapadmin) key=IMAGE_LDAPADMIN;; dnsmasq) key=IMAGE_DNSMASQ;; router) key=IMAGE_ROUTER;;
  esac
  grep "^${key}=" config/images.env | head -1 | cut -d= -f2- | sed -n 's/.*@\(sha256:[0-9a-f]*\)$/\1/p'
}

context_sha() {
  local svc="$1" ctx="services/$svc"
  { for f in "$ctx/Dockerfile" "$ctx"/*.sh "$ctx"/*.py "$ctx"/*.conf "$ctx"/*.template \
              config/images.env config/Caddyfile config/homepage/*.yaml config/ldap/*.ldif; do
      [[ -f "$f" ]] && { echo "--- $f"; sha256sum "$f"; }
    done; } 2>/dev/null | sha256sum | awk '{print $1}'
}

prepare_base_tags() {
  echo "== 准备本地基础镜像 tag（offline 复用 GHCR 层）=="
  local svc tag
  for svc in homepage caddy ldap ldapadmin; do
    tag="${BASE_TAG[$svc]}"
    if ! docker image inspect "$tag" >/dev/null 2>&1; then
      docker tag "${MIRROR_ID[$svc]}" "$tag" >/dev/null 2>&1 && echo "  tagged $tag" || echo "  ✗ 无法 tag $tag"
    else echo "  ✓ $tag"; fi
  done
  for svc in dnsmasq router; do
    docker image inspect "${BASE_TAG[$svc]}" >/dev/null 2>&1 && echo "  ✓ $svc base" || echo "  ✗ $svc base 缺"
  done
}

build_one() {
  local svc="$1"
  local ctx="services/$svc"
  local df="$ctx/Dockerfile"
  local image="orgflow/m0-$svc:v2"
  local base="${BASE_TAG[$svc]}"
  local udig
  udig="$(upstream_digest "$svc")"
  [[ -f "$df" ]] || { echo "✗ 缺 $df" >&2; return 1; }

  local tmpdir; tmpdir="$(mktemp -d /tmp/ofbuild-$svc.XXXXXX)"
  cp -a "$ctx/." "$tmpdir/"
  # FROM <真源>@sha256:<digest> → FROM <本地 base tag>（绕过 registry metadata 解析）
  sed -E "s#^FROM [^ ]+@sha256:[0-9a-f]+#FROM $base#" "$df" > "$tmpdir/Dockerfile"

  local -a args=(build --pull=false --network=none \
    --label "org.of.build=$(git rev-parse --short HEAD 2>/dev/null || echo local)" \
    --label "org.of.upstream-digest=$udig" \
    --label "org.of.service=$svc" -t "$image")
  [[ -n "$NO_CACHE" ]] && args+=("$NO_CACHE")
  args+=("$tmpdir")

  if ! docker "${args[@]}" >"/tmp/build-$svc.log" 2>&1; then
    echo "✗ $svc 构建失败：" >&2; tail -12 "/tmp/build-$svc.log" >&2
    rm -rf "$tmpdir"; return 1
  fi
  rm -rf "$tmpdir"

  local iid csha
  iid="$(docker image inspect "$image" --format '{{.Id}}' 2>/dev/null | sed 's/^sha256://')"
  csha="$(context_sha "$svc")"
  # 按 service 覆盖式累积（支持逐个 --only 构建后统一写 lock）
  local RESULT=/tmp/build-results.txt
  [[ -f "$RESULT" ]] || echo "# service|image|imageId|upstreamDigest|contextSha256" > "$RESULT"
  grep -v "^$svc|" "$RESULT" > "$RESULT.tmp" 2>/dev/null || true
  mv "$RESULT.tmp" "$RESULT"
  echo "$svc|$image|$iid|$udig|$csha" >> "$RESULT"
  echo "  ✓ $image id=${iid:0:19} upstream=${udig:7:19} ctx=${csha:0:12}"

  if [[ $NO_KEEP -eq 1 ]]; then
    docker rmi "$image" >/dev/null 2>&1
    docker builder prune -f >/dev/null 2>&1
  fi
  return 0
}

write_lock() {
  {
    echo "# 镜像锁定表（修复轮 T2：本分支自建 orgflow/m0-*；由 scripts/build-images.sh 回填）"
    echo "# 字段: service / tag / imageId / upstreamDigest / contextSha256"
    echo "# certs-init 复用 router，不单独构建。"
    printf 'service\ttag\timageId\tupstreamDigest\tcontextSha256\n'
    while IFS='|' read -r svc image iid udig csha; do
      [[ "$svc" == \#* || -z "$svc" ]] && continue
      printf '%s\t%s\t%s\t%s\t%s\n' "$svc" "$image" "$iid" "$udig" "$csha"
    done < /tmp/build-results.txt
  } > tests/images.lock
  echo "✓ 已写入 tests/images.lock（$(grep -c $'\t' tests/images.lock) 条）"
}

main() {
  # --only 模式保留已累积结果（逐个构建）；全量模式重新开始
  if [[ -z "$ONLY" || ! -f /tmp/build-results.txt ]]; then
    echo "# service|image|imageId|upstreamDigest|contextSha256" > /tmp/build-results.txt
  fi
  if [[ $DRY -eq 1 ]]; then
    echo "== dry-run：计划构建 =="
    local s; for s in "${SERVICES[@]}"; do echo "  $s -> orgflow/m0-$s:v2"; done
    echo "  certs-init 复用 router，不单独构建"; exit 0
  fi
  bash scripts/sync-build-context.sh >/dev/null
  prepare_base_tags
  local target rc=0
  for target in "${SERVICES[@]}"; do
    [[ -n "$ONLY" && "$ONLY" != "$target" ]] && continue
    echo "== 构建 $target =="
    build_one "$target" || rc=1
  done
  echo "== 构建结果 =="
  cat /tmp/build-results.txt
  write_lock

  if [[ $PUSH -eq 1 ]]; then
    echo "== --push：推送 GHCR（需写权限，失败不阻断）=="
    while IFS='|' read -r svc image iid udig csha; do
      [[ "$svc" == \#* || -z "$svc" ]] && continue
      docker tag "$image" "ghcr.nju.edu.cn/zeek-zhao/orgflow-devops/m0-$svc:v2" 2>/dev/null && \
      docker push "ghcr.nju.edu.cn/zeek-zhao/orgflow-devops/m0-$svc:v2" >/dev/null 2>&1 || echo "  ✗ push $svc 跳过"
    done < /tmp/build-results.txt
  fi
  return $rc
}

main "$@"
