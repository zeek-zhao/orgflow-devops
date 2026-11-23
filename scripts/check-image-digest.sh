#!/usr/bin/env bash
# check-image-digest.sh —— 镜像摘要门禁（NFR-01 / AC-1）
# 所有 compose 里的 image 必须带 @sha256:<64hex>，禁止 latest / 可变 tag。
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
rc=0
shopt -s nullglob
files=()
[[ -f docker-compose.yml ]] && files+=(docker-compose.yml)
for c in services/*/compose.yml; do [[ -f "$c" ]] && files+=("$c"); done
if [[ ${#files[@]} -eq 0 ]]; then echo "  - 暂无 compose，跳过"; exit 0; fi
re='@sha256:[0-9a-f]{64}$'
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
exit $rc
