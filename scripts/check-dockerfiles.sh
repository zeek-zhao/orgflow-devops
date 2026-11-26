#!/usr/bin/env bash
# check-dockerfiles.sh —— 每服务 Dockerfile 门禁（M2.4 Phase1，防止再漂移）
#
# 检查四项（文档 §2.3）：
#   1. 每个 services/*/（排除下划线脚手架）必须有 Dockerfile；
#   2. FROM 必须带 @sha256 锁定上游（允许 ARG BASE_DIGEST，但其默认值须为 sha256）；
#   3. 必须有 org.opencontainers.image.source LABEL；
#   4. config/images.env 的 UPSTREAM_<SVC> 与 Dockerfile FROM digest 一致。
#
# 退出非 0 表示有漂移；接入 check-fast.sh。
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
rc=0
n=0

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
