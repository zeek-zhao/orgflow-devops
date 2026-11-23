#!/usr/bin/env bash
# update-images-lock.sh —— 回填镜像上下文快照（配合 check-image-source.sh）
# 真实 digest 由 CI 联网构建后写入 config/images.env + tests/images.lock；
# 本脚本在确认源码已重建后，把当前上下文 hash 记为新基线。
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
mkdir -p out
cur="$( { shopt -s nullglob; for f in services/*/Dockerfile config/images.env services/*/*.conf services/*/*.py; do echo "--- $f"; sha256sum "$f"; done; } | sha256sum | awk '{print $1}' )"
echo "$cur" > out/images.context.sha
echo "✓ 已回填镜像上下文基线：$cur"
echo "  提示：联网环境请用真实构建 digest 更新 config/images.env 与 tests/images.lock"
