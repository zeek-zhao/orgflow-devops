#!/usr/bin/env bash
# down.sh —— 停止并移除全部容器（不动数据卷）。v1.0 §5.3 配套脚本。
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"
docker compose --env-file config/defaults.env -f docker-compose.yml down
echo "✓ 已停止全栈（数据卷保留）"
