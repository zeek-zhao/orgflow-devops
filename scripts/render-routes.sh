#!/usr/bin/env bash
# render-routes.sh —— make routes 调用：触发 router 重载 routes.yaml → Caddy reload
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
PORT="${P_ROUTER:-8083}"
code="$(curl -s -o /tmp/routes.out -w '%{http_code}' -X POST "http://127.0.0.1:${PORT}/render" || echo 000)"
echo "[routes] reload HTTP $code: $(cat /tmp/routes.out 2>/dev/null)"
case "$code" in
  200) exit 0 ;;
  422) echo "✗ 坏 upstream/host，未 reload" >&2; exit 1 ;;
  503) echo "✗ Caddy 不可达（router 降级），未 reload" >&2; exit 1 ;;
  *) echo "✗ 意外状态 $code" >&2; exit 1 ;;
esac
