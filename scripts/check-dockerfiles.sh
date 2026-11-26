#!/usr/bin/env bash
# check-dockerfiles.sh —— 每服务 Dockerfile 门禁（M2.4 Phase1，防止再漂移）
#
# 检查四项（文档 §2.3）：
#   1. 每个 services/*/（排除下划线脚手架）必须有 Dockerfile；
#   2. FROM 必须带 @sha256 锁定上游（允许 ARG BASE_DIGEST，但其默认值须为 sha256）；
#   3. 必须有 org.opencontainers.image.source LABEL；
#   4. config/images.env 的 UPSTREAM_<SVC> 与 Dockerfile FROM digest 一致。
#   5. (M2.5 P1-1) 有 Dockerfile 的服务，compose image fallback 必须引用本服务自己的镜像：
#      - HASHED（产本地 ctx 镜像）服务必须带 ctx- tag（防 gerrit 裸 tag / certs-init 复用 router）；
#      - M0 基线（官方 @sha256 mirror）服务镜像名必须含本服务标识；
#      EXEMPT 白名单只允许 _template。
#
# 退出非 0 表示有漂移；接入 check-fast.sh。
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
rc=0
n=0

# 走 ctx tag 的服务集合（与 check-images.sh HASHED 同口径）。
HASHED="jenkins jenkins-agent cgit registry builder gerrit certs-init"

for d in services/*/; do
  svc="${d#services/}"; svc="${svc%/}"
  [[ "$svc" == _* ]] && continue
  df="${d}Dockerfile"
  # (1) 存在性
  if [[ ! -f "$df" ]]; then
    echo "✗ $svc 缺 Dockerfile" >&2; rc=1; continue
  fi
  # (2) FROM @sha256（多阶段构建取最后一个 FROM 作为最终基底）
  from="$(grep '^FROM ' "$df" | tail -1 || true)"
  if [[ -z "$from" ]]; then
    echo "✗ $svc Dockerfile 无 FROM 指令" >&2; rc=1
  elif [[ "$from" == *'@sha256:'* ]]; then
    : # 直接 digest
  elif [[ "$from" == *'@${BASE_DIGEST}'* ]]; then
    bd="$(grep -m1 -E '^ARG BASE_DIGEST=sha256:' "$df" || true)"
    [[ -n "$bd" ]] || { echo "✗ $svc 用 @\${BASE_DIGEST} 但缺 ARG BASE_DIGEST=sha256: 默认值" >&2; rc=1; }
  else
    echo "✗ $svc FROM 未用 @sha256 锁定: $from" >&2; rc=1
  fi
  # (3) source LABEL
  if ! grep -q 'org.opencontainers.image.source' "$df"; then
    echo "✗ $svc Dockerfile 缺 org.opencontainers.image.source LABEL" >&2; rc=1
  fi
  # (5) M2.5 P1-1：compose 必须真正引用本服务的 Dockerfile 产物，不能"有文件不用"。
  imgtag="$(grep -m1 '^[[:space:]]*image:' "${d}compose.yml" 2>/dev/null || true)"
  fallback="${imgtag#*:-}"; fallback="${fallback%}"
  is_hashed=0
  case " $HASHED " in *" $svc "*) is_hashed=1;; esac
  if (( is_hashed )); then
    # 产本地 ctx 镜像的服务：fallback 必须带该服务的 ctx tag
    if ! printf '%s' "$fallback" | grep -qE -- "-${svc}:ctx-"; then
      echo "✗ $svc 有 Dockerfile 但 compose image 未引用本服务 ctx tag: ${fallback:-空}（疑似复用/裸 tag）" >&2; rc=1
    fi
  else
    # M0 基线：镜像名须含本服务标识（ldap 允许 openldap/phpldapadmin 等含子串）
    key="${svc%%-*}"  # certs-init 等连字符取首段兜底
    if ! printf '%s' "$fallback" | grep -qi -- "$key"; then
      echo "✗ $svc 有 Dockerfile 但 compose image 未引用本服务镜像: ${fallback:-空}（疑似复用其它服务）" >&2; rc=1
    fi
  fi
  n=$((n+1))
done

# (4) UPSTREAM_<SVC> 与 FROM digest 一致（能被 images.env 解析的才比）
if [[ -f config/images.env ]]; then
  for d in services/*/; do
    svc="${d#services/}"; svc="${svc%/}"
    [[ "$svc" == _* ]] && continue
    df="${d}Dockerfile"; [[ -f "$df" ]] || continue
    key="UPSTREAM_$(echo "$svc" | tr 'a-z-' 'A-Z_')"
    up="$(grep "^${key}=" config/images.env | head -1 | cut -d= -f2-)"
    [[ -n "$up" ]] || continue
    from="$(grep '^FROM ' "$df" | tail -1 || true)"
    dg=""
    if [[ "$from" == *'@sha256:'* ]]; then
      dg="${from##*@sha256:}"
      dg="sha256:${dg%% *}"
    elif [[ "$from" == *'@${BASE_DIGEST}'* ]]; then
      dg="$(grep -m1 -E '^ARG BASE_DIGEST=sha256:' "$df" | sed 's/^ARG BASE_DIGEST=//')"
    fi
    # ubuntu 基底：images.env 里 UPSTREAM_DNSMASQ/ROUTER/CGIT/CERTS_INIT 可能登记为 ubuntu digest
    if [[ -n "$dg" && "$dg" != "$up" ]]; then
      echo "✗ $svc UPSTREAM 不一致: images.env=$up Dockerfile=$dg" >&2; rc=1
    fi
  done
fi

if [[ $rc -eq 0 ]]; then
  echo "✓ Dockerfile 门禁：${n} 个服务均有 Dockerfile/FROM@sha256/source LABEL/UPSTREAM 一致"
fi
exit $rc
