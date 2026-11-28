#!/usr/bin/env bash
# prune-images.sh —— M3.0 镜像清理：仅删 dangling 镜像（不用 -a，保留在用 tag 与最近版本）
# 人工确认制：默认 dry-run，显式 CONFIRM=1 才真正执行 docker image prune。
set -euo pipefail

echo "=== 清理前 dangling 镜像 ==="
BEFORE="$(docker images -f dangling=true --format '{{.ID}}\t{{.Size}}' 2>/dev/null)"
if [ -z "$BEFORE" ]; then
  echo "(无 dangling 镜像，无需清理)"
  echo "RECLAIMED=0"
  exit 0
fi
echo "$BEFORE"
echo "合计: $(echo "$BEFORE" | wc -l) 个"

if [ "${CONFIRM:-0}" != "1" ]; then
  echo "--- dry-run（CONFIRM=1 才真正删除）---"
  echo "RECLAIMED=0 (dry-run)"
  exit 0
fi

echo "=== 执行 docker image prune -f（仅 dangling，不动在用 tag）==="
OUT="$(docker image prune -f 2>&1)"
echo "$OUT"
# 从输出解析回收字节（Docker 输出形如 "Total reclaimed space: 782.1MB"）
RECLAIMED="$(echo "$OUT" | grep -oE 'Total reclaimed space:.*' | sed 's/Total reclaimed space: *//' || echo unknown)"
echo "RECLAIMED=$RECLAIMED"

echo "=== 清理后 dangling ==="
docker images -f dangling=true --format '{{.ID}}\t{{.Size}}' 2>/dev/null || echo "(无)"
