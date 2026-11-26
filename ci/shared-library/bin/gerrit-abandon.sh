#!/usr/bin/env bash
# abandon 一个 Gerrit change（M2.4 Phase3 评审流探针清理用）。
# 依赖 env：GH_USER / GH_PASS（zeek.zhao HTTP Basic，由 Jenkins withCredentials 注入）。
# 可选：GERRIT_HOST、GERRIT_PORT、GHDR_HOST（canonicalWebUrl host，绕开 301）。
set -uo pipefail
CHANGE="${1:-}"
HOST="${GERRIT_HOST:-gerrit}"
PORT="${GERRIT_PORT:-8080}"
HDR_HOST="${GHDR_HOST:-orgflow-sandbox.tail0b7621.ts.net}"
[[ -n "$CHANGE" && -n "${GH_USER:-}" && -n "${GH_PASS:-}" ]] || { echo "usage: gerrit-abandon.sh <change> (需 GH_USER/GH_PASS)" >&2; exit 2; }

code="$(curl -s -o /dev/null -w '%{http_code}' -m 15 -u "$GH_USER:$GH_PASS" -X POST \
  -H "Host: $HDR_HOST" -H 'X-Forwarded-Proto: https' -H 'Content-Type: application/json' \
  --data-binary '{"message":"selfcheck probe cleanup"}' \
  "http://$HOST:$PORT/a/changes/$CHANGE/abandon" 2>/dev/null)"
echo "abandon change ${CHANGE} -> HTTP ${code}"
[[ "$code" == "200" || "$code" == "204" || "$code" == "409" ]] || exit 1
