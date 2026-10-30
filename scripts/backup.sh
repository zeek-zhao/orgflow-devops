#!/usr/bin/env bash
# M0 备份：停写、打包、校验、发布，再清理旧包。
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/backup-common.sh"

SERVICE="all"
MODE=""
NO_STOP=0
VERIFY=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --service|--verify)
      [ "$#" -ge 2 ] && [ -n "$2" ] || fail "$1 需要指定参数"
      [ -z "$MODE" ] || fail "--all / --service / --verify 不能重复或同用"
      MODE="$1"
      if [ "$1" = --service ]; then SERVICE="$2"; else VERIFY="$2"; fi
      shift 2 ;;
    --all)
      [ -z "$MODE" ] || fail "--all / --service / --verify 不能重复或同用"
      MODE="$1"; shift ;;
    --no-stop) NO_STOP=1; shift ;;
    *) fail "未知参数: $1" ;;
  esac
done
if [ "$MODE" = --verify ]; then
  [ "$NO_STOP" = 0 ] || fail "--verify 不能与 --no-stop 同用"
  verify_archive "$VERIFY"
  echo "校验通过: $VERIFY"
  exit 0
fi
RETENTION="${BACKUP_RETENTION_DAYS:-${RETENTION:-7}}"
case "$SERVICE" in
  jenkins|nexus|ldap|all) ;;
  *) fail "未知服务: $SERVICE" ;;
esac
if [ "${BACKUP_TARGET:-local}" != local ]; then
  fail "M0 仅支持 BACKUP_TARGET=local"
fi
if [[ ! "$RETENTION" =~ ^[0-9]{1,5}$ ]]; then
  fail "BACKUP_RETENTION_DAYS / RETENTION 必须为 0-99999 的整数"
fi
RETENTION=$((10#$RETENTION))
umask 077
mkdir -p "$BACKUP_DIR"
BACKUP_DIR="$(cd "$BACKUP_DIR" && pwd -P)"
ts=$(date +%Y%m%d-%H%M%S-%N)
work=""
pending_output=""
restart_service=""
cleanup() {
  local status=$?
  trap - EXIT
  if [ -n "$pending_output" ]; then
    if ! rm -f -- "$pending_output" "${pending_output%.tgz}.sha256" "${pending_output%.tgz}.meta"; then
      echo "清理未完成发布的备份失败: $pending_output" >&2
      status=1
    fi
  fi
  if [ -n "$work" ]; then
    if ! rm -f -- "$work/archive.tgz" "$work/archive.sha256" "$work/archive.meta"; then
      echo "清理备份临时文件失败: $work" >&2
      status=1
    fi
    if ! rmdir -- "$work"; then
      echo "清理备份临时目录失败: $work" >&2
      status=1
    fi
  fi
  if [ -n "$restart_service" ]; then
    echo "启回服务: $restart_service" >&2
    if ! "${COMPOSE_COMMAND[@]}" start "$restart_service"; then
      echo "无法启回 $restart_service，请人工处理" >&2
      status=1
    fi
  fi
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

targets=()
if [ "$SERVICE" = "all" ]; then
  targets=(jenkins nexus ldap)
else
  targets=("$SERVICE")
fi

for s in "${targets[@]}"; do
  vol="${VOLS[$s]}"
  # Never let docker run silently create a missing volume.
  docker volume inspect "$vol" >/dev/null
  exec {lock_fd}>"$BACKUP_DIR/.${s}.lock"
  flock -n "$lock_fd" || fail "$s 已有备份/恢复操作在执行"
  out="$BACKUP_DIR/${s}-${ts}.tgz"
  [ ! -e "$out" ] || fail "备份包已存在: $out"
  work="$(mktemp -d "$BACKUP_DIR/.${s}-${ts}.XXXXXX")"
  running="$(running_service "$s")" || fail "无法检查服务运行状态: $s"
  if [ -n "$running" ]; then
    if [ "$NO_STOP" = 1 ]; then
      echo "警告: --no-stop 对运行中的 $s 带写备份，可能不一致" >&2
    else
      restart_service="$s"
      stop_service "$s"
    fi
  fi
  echo "备份 $s ($vol) -> $out"
  docker run --rm \
    -v "${vol}:/data:ro" \
    alpine tar czf - -C /data . >"$work/archive.tgz"
  tar tzf "$work/archive.tgz" >/dev/null || fail "tar 校验失败，删除损坏包: $out"
  digest="$(sha256sum "$work/archive.tgz")"
  printf '%s  %s\n' "${digest:0:64}" "$(basename "$out")" >"$work/archive.sha256"
  {
    printf 'service=%s\nvolume=%s\ncreated_at=%s\n' "$s" "$vol" "$(date -u +%FT%TZ)"
    printf 'bytes=%s\nfiles=%s\nretention_days=%s\n' \
      "$(wc -c <"$work/archive.tgz")" \
      "$(tar tzf "$work/archive.tgz" | wc -l)" "$RETENTION"
  } >"$work/archive.meta"
  pending_output="$out"
  mv -- "$work/archive.sha256" "${out%.tgz}.sha256"
  mv -- "$work/archive.meta" "${out%.tgz}.meta"
  mv -- "$work/archive.tgz" "$out"
  pending_output=""
  rmdir -- "$work"
  work=""
  if [ -n "$restart_service" ]; then
    "${COMPOSE_COMMAND[@]}" start "$restart_service"
    restart_service=""
  fi
  # Keep all acquired locks until retention completes and this process exits.
done

if [ "$RETENTION" = 0 ]; then
  echo "RETENTION=0：拒绝清理，0 天无意义；本次备份正常保留" >&2
else
  echo "清理超过 ${RETENTION} 天的备份（排除本次 ${ts}）"
  for s in "${targets[@]}"; do
    find "$BACKUP_DIR" -maxdepth 1 -type f -name "${s}-*.tgz" \
      ! -name "${s}-${ts}.tgz" -mtime +"$RETENTION" \
      -exec sh -ec 'for old do rm -f -- "$old" "${old%.tgz}.sha256" "${old%.tgz}.meta"; done' sh {} +
  done
fi
echo "完成"
