#!/usr/bin/env bash
# doctor.sh —— 只读环境自检（NFR-04：不改状态）
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
rc=0
ok(){ echo "✓ $*"; }; bad(){ echo "✗ $*" >&2; rc=1; }
command -v docker >/dev/null && ok "docker 已安装" || bad "缺 docker"
docker info >/dev/null 2>&1 && ok "docker daemon 可用" || bad "docker daemon 不可用"
docker compose version >/dev/null 2>&1 && ok "compose 插件可用" || bad "缺 compose 插件"
command -v openssl >/dev/null && ok "openssl 可用" || bad "缺 openssl"
command -v python3 >/dev/null && ok "python3 可用" || bad "缺 python3"
[[ -f config/defaults.env ]] && ok "配置存在" || bad "缺 config/defaults.env"
[[ -f config/images.env ]] && ok "镜像清单存在" || bad "缺 config/images.env"
# 端口占用只读检查（仅告警）
if command -v ss >/dev/null 2>&1 && ss -lnt 2>/dev/null | grep -qE ':(80|443)[[:space:]]'; then
  echo "⚠ 宿主 80/443 已被占用（部署前确认）"
fi
[[ $rc -eq 0 ]] && echo "✓ 环境自检通过（只读，未改任何状态）"
exit $rc
