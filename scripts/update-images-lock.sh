#!/usr/bin/env bash
# update-images-lock.sh —— 回填镜像上下文快照（配合 check-image-source.sh）
# 2026-11-24 改版：镜像对齐 main 后无本地构建，digest 取自 main 的 tests/images.lock；
# 本脚本把「以卷注入的配置」当前 hash 记为新基线。
set -euo pipefail
shopt -s nullglob
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
mkdir -p out
CTX_FILES=(services/*/Dockerfile config/images.env config/Caddyfile config/ldap/*.ldif
           config/homepage/*.yaml services/*/*.conf services/*/*.py services/*/*.sh)
cur="$( { for f in "${CTX_FILES[@]}"; do echo "--- $f"; sha256sum "$f"; done; } | sha256sum | awk '{print $1}' )"
echo "$cur" > out/images.context.sha
echo "✓ 已回填镜像上下文基线：$cur"
echo "  提示：镜像 digest 必须与 main 的 tests/images.lock 逐字节一致"
