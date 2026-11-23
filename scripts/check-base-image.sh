#!/usr/bin/env bash
# check-base-image.sh —— 镜像来源门禁（NFR-02，2026-11-24 改版）
#
# 旧口径：所有 services/*/Dockerfile 必须 FROM ubuntu:24.04@sha256。
# 新口径（Issue #194）：镜像全部对齐 main 分支同款——官方 mirror-* 或 main CI 产物，
#   本仓不再基于 ubuntu 自建镜像。因此断言：
#   1) services/* 下不得再有 Dockerfile（有即为 ubuntu 自建回潮）；
#   2) 每个 compose 的 image 必须来自 zeek-zhao/orgflow-devops（本仓/main 发布）。
# 这样把「不要基于 ubuntu 自建」变成可自动检出的红线，而非口头约定。
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
rc=0
shopt -s nullglob

dockerfiles=(services/*/Dockerfile)
if (( ${#dockerfiles[@]} > 0 )); then
  echo "✗ 发现本地自建 Dockerfile（应对齐 main 镜像，不要在 ubuntu 上自建）:" >&2
  printf '  %s\n' "${dockerfiles[@]}" >&2
  rc=1
fi

composes=(docker-compose.yml services/*/compose.yml)
src_re='zeek-zhao/orgflow-devops/'
for f in "${composes[@]}"; do
  [[ -f "$f" ]] || continue
  while IFS= read -r line; do
    [[ "$line" =~ ^[[:space:]]*-?[[:space:]]*image:[[:space:]]* ]] || continue
    img="$(echo "$line" | sed -E 's/^[[:space:]]*-?[[:space:]]*image:[[:space:]]*//; s/[[:space:]]+$//')"
    [[ "$img" == *"$src_re"* ]] || { echo "✗ $f 镜像非本仓/main 发布源: $img" >&2; rc=1; }
  done < "$f"
done

[[ $rc -eq 0 ]] && echo "✓ 镜像来源统一：无本地 ubuntu 自建，全部来自 zeek-zhao/orgflow-devops"
exit $rc
