#!/usr/bin/env bash
# render-routes.sh —— make routes 调用：容器内触发 router 重载 routes.yaml → Caddy reload
# 修复轮 T1（安全收口）：POST /render 仅允许容器内本机（127.0.0.1/::1），
# 禁止再从宿主机经映射端口调用；router 容器无 curl，改用 --render CLI 入口。
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

PFX="${CONTAINER_PREFIX:-of}"
CT="docker exec ${PFX}-router"

out="$($CT python3 /app/server.py --render 2>&1)"
code=$?
echo "[routes] $out"

# CLI 退出码：0=成功/幂等，非 0=失败（422 坏配置 / 503 caddy 不可达）
case "$code" in
  0) exit 0 ;;
  *) echo "✗ 容器内 render 失败（exit=$code）；检查 docker logs ${PFX}-router" >&2; exit 1 ;;
esac
