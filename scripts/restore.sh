#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/backup-common.sh"

SERVICE=""
FILE=""
FORCE=0
DRY_RUN=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --service|--file)
      [ "$#" -ge 2 ] && [ -n "$2" ] || fail "$1 需要指定参数"
      if [ "$1" = --service ]; then SERVICE="$2"; else FILE="$2"; fi
      shift 2 ;;
    --force) FORCE=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    *) fail "未知参数: $1" ;;
  esac
done
case "$SERVICE" in
  jenkins|nexus|ldap) ;;
  *) fail "未知服务: $SERVICE；用法: restore.sh --service jenkins|nexus|ldap --file path.tgz [--force] [--dry-run]" ;;
esac
[ -n "$FILE" ] || fail "--file 必填"
[ -f "$FILE" ] || fail "备份包不存在或不是普通文件: $FILE"
FILE="$(realpath -e -- "$FILE")"
verify_archive "$FILE"
vol="${VOLS[$SERVICE]}"
meta="${FILE%.tgz}.meta"
if [ -e "$meta" ]; then
  [ -f "$meta" ] && [ -r "$meta" ] || fail "meta 不是可读普通文件: $meta"
  grep -Fxq "service=$SERVICE" "$meta" &&
    grep -Fxq "volume=$vol" "$meta" || fail "meta 服务/卷与恢复目标不匹配"
fi
# Refuse traversal, escaping links and device nodes before stopping or clearing.
python3 - "$FILE" <<'PY'
import posixpath
import sys
import tarfile

def safe(path):
    normalized = posixpath.normpath(path)
    return not path.startswith("/") and normalized != ".." and not normalized.startswith("../")

with tarfile.open(sys.argv[1], "r:gz") as archive:
    for member in archive:
        if not safe(member.name) or not (member.isfile() or member.isdir() or member.issym() or member.islnk()):
            sys.exit("不安全的 tar 条目: " + member.name)
        if member.issym() or member.islnk():
            target = member.linkname
            if member.issym():
                target = posixpath.join(posixpath.dirname(member.name), target)
            if not safe(target):
                sys.exit("不安全的 tar 链接: " + member.name)
PY

umask 077
mkdir -p "$BACKUP_DIR"
exec {lock_fd}>"$BACKUP_DIR/.${SERVICE}.lock"
flock -n "$lock_fd" || fail "$SERVICE 已有备份/恢复操作在执行"
docker volume inspect "$vol" >/dev/null
count_entries() {
  docker run --rm -v "${vol}:/data:ro" alpine \
    sh -ec 'set -o pipefail; find /data -mindepth 1 -print | wc -l'
}
check_empty() {
  entries="$(count_entries)"
  [[ "$entries" =~ ^[[:space:]]*[0-9]+[[:space:]]*$ ]] || fail "无法读取卷条目数"
  if (( entries > 0 )) && [ "$FORCE" = 0 ]; then
    fail "目标卷非空，现有条目数: $entries；必须指定 --force"
  fi
}
check_empty
echo "恢复计划: $FILE -> $SERVICE ($vol)，现有条目数: $entries"
echo "停止 $SERVICE -> 清空卷内容（保留卷本身）-> 解包 -> 启回 $SERVICE"
if [ "$DRY_RUN" = 1 ]; then
  echo "dry-run：未停止服务、未修改卷"
  exit 0
fi
container_exists "$SERVICE" ||
  fail "服务容器不存在，请先部署 $SERVICE 后再恢复"
stopped=0
on_exit() {
  local status=$?
  if [ "$status" != 0 ] && [ "$stopped" = 1 ]; then
    echo "恢复失败；$SERVICE 保持停止，请检查卷与备份后重试，勿直接启动半恢复数据" >&2
  fi
}
trap on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
stop_service "$SERVICE"
stopped=1
# Recheck after stop: entries may have appeared since the initial preflight.
check_empty
docker run --rm -i -v "${vol}:/data" alpine \
  sh -ec 'find /data -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +; tar xzpf - -C /data' <"$FILE"
start_service "$SERVICE"
stopped=0
echo "恢复完成: service=$SERVICE volume=$vol file=$FILE 原条目数=$entries"
echo "服务已启回；请按 docs/备份与恢复.md 检查 healthy 与业务数据。"
