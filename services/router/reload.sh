#!/usr/bin/env bash
# 渲染 routes.yaml 并热加载到 Caddy（一次性执行版）
set -euo pipefail
ADMIN="${CADDY_ADMIN_URL:-http://localhost:2019}"
CADDYFILE="${1:-out/Caddyfile}"
ROUTES="${ROUTES_FILE:-config/routes.yaml}"

python3 services/router/render.py --routes "$ROUTES" --out "$CADDYFILE"

if [ -f "$CADDYFILE" ]; then
  code=$(curl -sS -o /dev/null -w '%{http_code}' -X POST \
    "$ADMIN/load" -H 'Content-Type: text/caddyfile' --data-binary @"$CADDYFILE" || true)
  echo "caddy reload http=$code"
fi
