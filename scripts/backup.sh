#!/usr/bin/env bash
# M0 备份：把指定服务的数据卷打包到 BACKUP_DIR，并按保留天数清理
set -euo pipefail

SERVICE="all"
[ "${1:-}" = "--service" ] && SERVICE="${2:-all}"
[ "${1:-}" = "--all" ] && SERVICE="all"

BACKUP_DIR="${BACKUP_DIR:-./out/backups}"
RETENTION="${BACKUP_RETENTION_DAYS:-7}"
PROJECT="orgflow-devops"
mkdir -p "$BACKUP_DIR"
ts=$(date +%Y%m%d-%H%M%S)

declare -A VOLS=(
  [jenkins]="${PROJECT}_jenkins_home"
  [nexus]="${PROJECT}_nexus_data"
  [ldap]="${PROJECT}_ldap_data"
)

targets=()
if [ "$SERVICE" = "all" ]; then
  targets=(jenkins nexus ldap)
else
  targets=("$SERVICE")
fi

for s in "${targets[@]}"; do
  vol="${VOLS[$s]:-}"
  if [ -z "$vol" ]; then
    echo "跳过未知服务: $s" >&2
    continue
  fi
  out="$BACKUP_DIR/${s}-${ts}.tgz"
  echo "备份 $s ($vol) -> $out"
  docker run --rm \
    -v "${vol}:/data:ro" \
    -v "$(cd "$BACKUP_DIR" && pwd):/backup" \
    alpine tar czf "/backup/${s}-${ts}.tgz" -C /data .
done

echo "清理超过 ${RETENTION} 天的备份"
find "$BACKUP_DIR" -name '*.tgz' -mtime +"$RETENTION" -delete || true
echo "完成"
