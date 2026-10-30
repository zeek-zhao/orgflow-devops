#!/usr/bin/env bash
# 渲染 routes.yaml 并热加载到 Caddy（一次性执行版）
set -euo pipefail
ADMIN="${CADDY_ADMIN_URL:-http://localhost:2019}"
CADDYFILE="${1:-out/Caddyfile}"
ROUTES="${ROUTES_FILE:-config/routes.yaml}"

exec python3 services/router/render.py \
  --routes "$ROUTES" --out "$CADDYFILE" --admin "$ADMIN"
