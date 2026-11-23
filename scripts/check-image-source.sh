#!/usr/bin/env bash
# check-image-source.sh —— 镜像来源闸门（NFR-01）
# 镜像上下文（Dockerfile / 各服务配置）改动后，若 images.lock 未同步更新，拒绝部署。
# 用内容 hash 快照 out/images.context.sha 比对；首次运行生成快照（视为基线）。
# 反证：改任一 Dockerfile → 本脚本红；make images-lock 回填 → 复绿。
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
SNAP="out/images.context.sha"
mkdir -p out
cur="$( { shopt -s nullglob; for f in services/*/Dockerfile config/images.env services/*/*.conf services/*/*.py; do echo "--- $f"; sha256sum "$f"; done; } | sha256sum | awk '{print $1}' )"
if [[ ! -f "$SNAP" ]]; then
  echo "$cur" > "$SNAP"
  echo "✓ 已生成镜像上下文基线快照（$cur）—— 首次运行"
  exit 0
fi
prev="$(cat "$SNAP")"
if [[ "$prev" == "$cur" ]]; then
  echo "✓ 镜像上下文未变，允许部署"
  exit 0
fi
echo "✗ 镜像上下文已变但未回填 digest：$(cat "$SNAP") → $cur" >&2
echo "  执行 make images-lock 回填后重试" >&2
exit 1
