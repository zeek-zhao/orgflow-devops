#!/usr/bin/env bash
# check-base-image.sh —— 基底统一门禁（NFR-02）
# 所有 services/*/Dockerfile 的 FROM 必须是 ubuntu:24.04@sha256:<64hex>。
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
rc=0
shopt -s nullglob
files=(services/*/Dockerfile)
if [[ ${#files[@]} -eq 0 ]]; then echo "  - 暂无 Dockerfile，跳过"; exit 0; fi
re='^FROM ubuntu:24\.04@sha256:[0-9a-f]{64}([[:space:]]|$)'
for f in "${files[@]}"; do
  while IFS= read -r line; do
    [[ "$line" =~ ^FROM[[:space:]] ]] || continue
    if [[ "$line" =~ $re ]]; then :; else
      echo "✗ $f 基底不合规: $line" >&2; rc=1
    fi
  done < "$f"
done
[[ $rc -eq 0 ]] && echo "✓ 基底统一：${#files[@]} 个 Dockerfile 全部 ubuntu:24.04@sha256"
exit $rc
