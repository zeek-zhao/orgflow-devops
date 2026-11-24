#!/bin/sh
# 镜像内健康检查：validate 配置 + admin /config/ 探活（真叠加内容）
set -e
caddy validate --config /etc/caddy/Caddyfile >/dev/null 2>&1
ADMIN="${CADDY_ADMIN:-http://127.0.0.1:2019}"
wget -q -O - "$ADMIN/config/" >/dev/null 2>&1 || \
  python3 -c "import urllib.request;urllib.request.urlopen('$ADMIN/config/',timeout=3)" >/dev/null 2>&1
