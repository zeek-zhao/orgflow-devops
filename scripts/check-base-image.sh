#!/usr/bin/env bash
# check-base-image.sh —— 自建镜像基底门禁（v1.0 §4 / NFR-02）
#
# 口径（按 v1.0 定稿，取代 2026-11-24「不许自建」的旧口径）：
#   1) 自建服务（dnsmasq / router）必须有 Dockerfile，且 FROM ubuntu:24.04@fe815609…；
#   2) 薄封装服务（caddy/ldap/ldapadmin/homepage）的 FROM 由 check-upstream-digest.sh 校验；
#   3) 所有 compose 的 image 必须来自 zeek-zhao/orgflow-devops（本 GHCR 仓库）。
# 上游 digest 登记表的唯一真源在 docs/engineering/镜像与供应链.md。
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
rc=0
shopt -s nullglob
UBUNTU_DIGEST='sha256:fe81560990fae86dc4743202b2cb4d3df98d0bcf949173cecef15ce1127ef852'

# 1) 自建服务必须有 Dockerfile 且基底 digest 正确
for svc in dnsmasq router; do
  df="services/$svc/Dockerfile"
  if [[ ! -f "$df" ]]; then echo "✗ 缺自建镜像 Dockerfile: $df" >&2; rc=1; continue; fi
  from="$(grep -m1 '^FROM ' "$df" | awk '{print $2}')"
  if [[ "$from" != "ubuntu:24.04@$UBUNTU_DIGEST" ]]; then
    echo "✗ $df 基底应为 ubuntu:24.04@${UBUNTU_DIGEST:0:19}…，实为 $from" >&2; rc=1
  fi
done

composes=(docker-compose.yml services/*/compose.yml)
src_re='zeek-zhao/orgflow-devops/'
for f in "${composes[@]}"; do
  [[ -f "$f" ]] || continue
  while IFS= read -r line; do
    [[ "$line" =~ ^[[:space:]]*-?[[:space:]]*image:[[:space:]]* ]] || continue
    img="$(echo "$line" | sed -E 's/^[[:space:]]*-?[[:space:]]*image:[[:space:]]*//; s/[[:space:]]+$//')"
    [[ "$img" == *"$src_re"* ]] || { echo "✗ $f 镜像非本仓 GHCR 源: $img" >&2; rc=1; }
  done < "$f"
done

[[ $rc -eq 0 ]] && echo "✓ 镜像基底统一：2 自建(ubuntu@digest) + 4 薄封装(登记表) + compose 全来自本仓 GHCR"
exit $rc
