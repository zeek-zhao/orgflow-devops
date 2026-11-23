#!/usr/bin/env bash
# render.sh —— 把 config/defaults.env 渲染为 out/runtime.env（非敏感产物）
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
mkdir -p out
{
  echo "# 由 scripts/render.sh 生成，勿手改"
  cp config/defaults.env /dev/stdout 2>/dev/null | grep -vE '^\s*#|^\s*$'
} > out/runtime.env
echo "✓ 已渲染 out/runtime.env（$(wc -l < out/runtime.env) 行）"
