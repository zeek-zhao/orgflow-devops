#!/usr/bin/env bash
# drill-down.sh —— M3.0.1 T3 清理隔离栈：只停 orgflow-drill project 与网络，删解包目录；日志保留。
# 生产 13 容器不受影响（独立 project/网络/容器名，全部 drill- 前缀）。
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"
CDIR="$REPO/deploy/drill"

echo "=== T3 隔离栈清理 $(date -u +%FT%TZ) ==="
# 1) 停并删 drill project（含其容器；-v 删 compose 内匿名卷，本 compose 无匿名卷）
docker compose --env-file config/defaults.env -f "$CDIR/compose.yml" down -v --remove-orphans 2>&1 | tail -8 || true
# 2) 删独立网络（若残留）
docker network rm orgflow-drill_net >/dev/null 2>&1 || true
# 3) 删解包数据目录（日志保留在 /data/drill-logs）
rm -rf /data/drill/orgflow-drill
# 4) 断言无残留
left=$(docker ps -a --format '{{.Names}}' | grep -c '^drill-' || true)
net=$(docker network ls --format '{{.Name}}' | grep -c '^orgflow-drill_net$' || true)
prod=$(docker ps -q | wc -l)
echo "[drill-down] drill 容器残留=$left drill 网络残留=$net 生产容器=$prod"
if [ "$left" -ne 0 ] || [ "$net" -ne 0 ]; then
  echo "✗ drill 清理不彻底"; exit 1
fi
echo "✓ drill 栈已清理，日志保留在 /data/drill-logs/，解包数据已删"
