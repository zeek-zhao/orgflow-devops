#!/usr/bin/env bash
# Shared volume mapping and archive checks for backup/restore.
set -euo pipefail

BACKUP_DIR="${BACKUP_DIR:-./out/backups}"
read -r -a COMPOSE_COMMAND <<< "${COMPOSE:-docker compose}"
if [ -n "${ENV_FILE:-}" ]; then
  COMPOSE_COMMAND+=(--env-file "$ENV_FILE")
fi

# Nexus 在 #46 之后移出 docker-compose.yml，改由 job `nexus-deploy` 调
# scripts/nexus-deploy.sh 用 `docker run` 拉起。所以 compose 的 ps/stop/start
# 对它一律报 `no such service: nexus` —— 备份/恢复必须按服务分派到 docker。
NEXUS_CONTAINER="${NEXUS_CONTAINER:-of-nexus}"

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

# 以下四个函数是「服务运行时」抽象：compose 管理的服务走 compose，
# 移出 compose 的 nexus 走 docker。判据保持一致 —— 状态判断失败必须报错，
# 不能把「查不到」当成「没在跑」（那会让带写备份静默地跑在不一致的状态上）。

container_exists() {
  case "$1" in
    nexus)
      docker container inspect "$NEXUS_CONTAINER" >/dev/null 2>&1 ;;
    *)
      [ -n "$("${COMPOSE_COMMAND[@]}" ps -a -q "$1")" ] ;;
  esac
}

running_service() {
  case "$1" in
    nexus)
      if [ "$(docker inspect "$NEXUS_CONTAINER" \
            --format '{{.State.Running}}' 2>/dev/null || echo false)" = "true" ]; then
        echo "$NEXUS_CONTAINER"
      fi ;;
    *)
      "${COMPOSE_COMMAND[@]}" ps --status running -q "$1" ;;
  esac
}

stop_service() {
  local running
  case "$1" in
    nexus)
      docker stop -t 120 "$NEXUS_CONTAINER" >/dev/null ||
        fail "无法停止 Nexus 容器: $NEXUS_CONTAINER"
      running="$(running_service nexus)" || fail "无法确认 Nexus 已停止"
      [ -z "$running" ] || fail "Nexus 仍在运行，拒绝带写操作: $NEXUS_CONTAINER" ;;
    *)
      "${COMPOSE_COMMAND[@]}" stop -t 120 "$1" || fail "无法停止服务: $1"
      running="$(running_service "$1")" || fail "无法确认服务已停止: $1"
      [ -z "$running" ] || fail "服务仍在运行，拒绝带写操作: $1" ;;
  esac
}

start_service() {
  case "$1" in
    nexus) docker start "$NEXUS_CONTAINER" >/dev/null ;;
    *) "${COMPOSE_COMMAND[@]}" start "$1" ;;
  esac
}
