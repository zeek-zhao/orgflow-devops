#!/usr/bin/env bash
# Shared volume mapping and archive checks for backup/restore.
set -euo pipefail

BACKUP_DIR="${BACKUP_DIR:-./out/backups}"
read -r -a COMPOSE_COMMAND <<< "${COMPOSE:-docker compose}"
if [ -n "${ENV_FILE:-}" ]; then
  COMPOSE_COMMAND+=(--env-file "$ENV_FILE")
fi

# Compose service -> named volume (docker-compose.yml project: orgflow-devops).
declare -A VOLS=(
  [jenkins]="orgflow-devops_jenkins_home"
  [nexus]="orgflow-devops_nexus_data"
  [ldap]="orgflow-devops_ldap_data"
)

fail() {
  echo "$*" >&2
  exit 1
}

verify_archive() {
  local archive="$1" checksum expected actual line
  [ -f "$archive" ] && [ -r "$archive" ] || fail "备份包不存在或不是可读普通文件: $archive"
  [[ "$archive" == *.tgz ]] || fail "备份包必须为 .tgz: $archive"
  checksum="${archive%.tgz}.sha256"
  if [ -e "$checksum" ]; then
    [ -f "$checksum" ] && [ -r "$checksum" ] || fail "校验清单不是可读普通文件: $checksum"
    line="$(cat -- "$checksum")"
    expected="${line:0:64}"
    [[ "$expected" =~ ^[0-9a-f]{64}$ ]] &&
      [ "${line:64}" = "  $(basename -- "$archive")" ] ||
      fail "sha256 清单格式或文件名不匹配: $checksum"
    actual="$(sha256sum -- "$archive")"
    [ "${actual:0:64}" = "$expected" ] || fail "sha256 校验失败: $archive"
  else
    echo "警告: 缺少 sha256 清单，仅校验 tar 可读性: $archive" >&2
  fi
  tar tzf "$archive" >/dev/null || fail "tar 校验失败，备份包损坏: $archive"
}

running_service() {
  "${COMPOSE_COMMAND[@]}" ps --status running -q "$1"
}

stop_service() {
  local running
  "${COMPOSE_COMMAND[@]}" stop -t 120 "$1" || fail "无法停止服务: $1"
  running="$(running_service "$1")" || fail "无法确认服务已停止: $1"
  [ -z "$running" ] || fail "服务仍在运行，拒绝带写操作: $1"
}
