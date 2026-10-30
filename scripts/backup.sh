#!/usr/bin/env bash
# M0 备份：把指定服务的数据卷打包到 BACKUP_DIR，并按保留天数清理
set -euo pipefail

SERVICE="all"
case "${1:-}" in
  --service)
    if [ "$#" != 2 ] || [ -z "$2" ]; then
      echo "用法: backup.sh [--all | --service jenkins|nexus|ldap|all]" >&2
      exit 1
    fi
    SERVICE="$2" ;;
  --all|"")
    if [ "$#" -gt 1 ]; then
      echo "参数过多" >&2
      exit 1
    fi ;;
  *) echo "未知参数: $1" >&2; exit 1 ;;
esac

BACKUP_DIR="${BACKUP_DIR:-./out/backups}"
RETENTION="${BACKUP_RETENTION_DAYS:-7}"
case "$SERVICE" in
  jenkins|nexus|ldap|all) ;;
  *) echo "未知服务: $SERVICE" >&2; exit 1 ;;
esac
if [ "${BACKUP_TARGET:-local}" != local ]; then
  echo "M0 仅支持 BACKUP_TARGET=local" >&2
  exit 1
fi
if [[ ! "$RETENTION" =~ ^[0-9]{1,5}$ ]]; then
  echo "BACKUP_RETENTION_DAYS 必须为 0-99999 的整数" >&2
  exit 1
fi
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
  vol="${VOLS[$s]}"
  # docker run would silently create a missing volume and back up an empty directory.
  docker volume inspect "$vol" >/dev/null
  out="$BACKUP_DIR/${s}-${ts}.tgz"
  echo "备份 $s ($vol) -> $out"
  docker run --rm \
    -v "${vol}:/data:ro" \
    -v "$(cd "$BACKUP_DIR" && pwd):/backup" \
    alpine tar czf "/backup/${s}-${ts}.tgz" -C /data .
done

echo "清理超过 ${RETENTION} 天的备份"
for s in "${targets[@]}"; do
  find "$BACKUP_DIR" -type f -name "${s}-*.tgz" -mtime +"$RETENTION" -delete
done
echo "完成"
