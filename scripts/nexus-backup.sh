#!/usr/bin/env bash
# Nexus 备份 + 内容校验 + 恢复演练（#93 / REQ-M0-B5）
#
# 为什么不是直接 `backup.sh --service nexus` 就完事：
#   backup.sh 只保证「整卷 tar 得出来、sha256 对得上」，它不知道 Nexus 的数据
#   分 db/ 与 blobs/ 两处。只备一半的包能通过 tar 与 sha256，恢复出来却是残缺
#   实例 —— 这条链路由本脚本补齐：
#     1. 备份（复用 backup.sh，停写后打包，保证 H2 与 blob store 同一时刻）
#     2. 内容校验（check_nexus_archive.py：db + blobs 双要件）
#     3. 恢复演练（解到**独立 drill 卷**，绝不碰 orgflow-devops_nexus_data）
#        a. db 文件 sha256 与归档内一致
#        b. blob 文件数与总字节与归档内一致
#        c. 可选 boot check：用 drill 卷起一个临时 Nexus，等到 "Started Sonatype Nexus"
#
# 用法：
#   bash scripts/nexus-backup.sh                      # 备份 + 校验 + 演练
#   bash scripts/nexus-backup.sh --archive out/backups/nexus-xxx.tgz
#   bash scripts/nexus-backup.sh --no-restore-drill   # 只备份 + 校验
#   bash scripts/nexus-backup.sh --no-boot-check      # 演练但不启容器
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/backup-common.sh"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARCHIVE=""
RETENTION="${BACKUP_RETENTION_DAYS:-7}"
DRILL=1
BOOT_CHECK=1
KEEP_DRILL=0
NEXUS_CONTAINER="${NEXUS_CONTAINER:-of-nexus}"
NEXUS_IMAGE="${NEXUS_IMAGE:-}"
BOOT_TIMEOUT="${BOOT_TIMEOUT:-240}"
DRILL_VOL=""
DRILL_CT=""
DRILL_READY=0

log() { printf '%s\n' "$*"; }
step() { printf '\n== %s ==\n' "$*"; }

cleanup() {
  local status=$?
  trap - EXIT
  if [ -n "$DRILL_CT" ]; then
    docker rm -f "$DRILL_CT" >/dev/null 2>&1 || true
  fi
  if [ -n "$DRILL_VOL" ]; then
    if [ "$KEEP_DRILL" = 1 ]; then
      log "保留演练卷（--keep-drill-volume）: $DRILL_VOL"
    else
      docker volume rm "$DRILL_VOL" >/dev/null 2>&1 || true
    fi
  fi
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

while [ "$#" -gt 0 ]; do
  case "$1" in
    --archive)
      [ "$#" -ge 2 ] && [ -n "$2" ] || fail "--archive 需要指定备份包"
      ARCHIVE="$2"; shift 2 ;;
    --retention)
      [ "$#" -ge 2 ] && [ -n "$2" ] || fail "--retention 需要指定天数"
      RETENTION="$2"; shift 2 ;;
    --no-restore-drill) DRILL=0; shift ;;
    --no-boot-check) BOOT_CHECK=0; shift ;;
    --keep-drill-volume) KEEP_DRILL=1; shift ;;
    *) fail "未知参数: $1" ;;
  esac
done
if [ "$DRILL" = 0 ] && [ "$BOOT_CHECK" = 1 ]; then
  BOOT_CHECK=0
fi

# --- 1. 备份（或使用指定包）-------------------------------------------------
if [ -z "$ARCHIVE" ]; then
  step "备份 Nexus（停写 → 整卷打包 → 启回）"
  BACKUP_RETENTION_DAYS="$RETENTION" bash "$HERE/backup.sh" --service nexus
  ARCHIVE="$(find "$BACKUP_DIR" -maxdepth 1 -type f -name 'nexus-*.tgz' -printf '%T@ %p\n' \
    | sort -rn | awk 'NR==1{sub(/^[^ ]+ /,"");print}')"
  [ -n "$ARCHIVE" ] || fail "备份完成后找不到 nexus-*.tgz（BACKUP_DIR=$BACKUP_DIR）"
else
  [ -f "$ARCHIVE" ] || fail "备份包不存在: $ARCHIVE"
fi
ARCHIVE="$(cd "$(dirname "$ARCHIVE")" && pwd -P)/$(basename "$ARCHIVE")"
verify_archive "$ARCHIVE"

step "备份包"
log "  路径: $ARCHIVE"
log "  字节: $(wc -c <"$ARCHIVE")"
log "  sha256: $(sha256sum "$ARCHIVE" | cut -c1-64)"

# --- 2. 内容校验（db + blobs 双要件）---------------------------------------
step "内容校验：H2 数据库 + blob store"
python3 "$HERE/check_nexus_archive.py" "$ARCHIVE"
JSON="$(python3 "$HERE/check_nexus_archive.py" --json "$ARCHIVE")"
read -r ARCH_BLOB_FILES ARCH_BLOB_BYTES ARCH_DB_BYTES < <(
  printf '%s' "$JSON" | python3 -c '
import json, sys
d = json.load(sys.stdin)
print(sum(s["files"] for s in d["blob_stores"]),
      d["blob_bytes"],
      (d["db"] or {}).get("bytes", 0))
')
log "  归档内: db=${ARCH_DB_BYTES}B · blobs=${ARCH_BLOB_FILES} 文件 / ${ARCH_BLOB_BYTES}B"

# --- 3. 恢复演练 ------------------------------------------------------------
if [ "$DRILL" = 0 ]; then
  step "跳过恢复演练（--no-restore-drill）"
  log "✓ 备份与内容校验通过: $ARCHIVE"
  exit 0
fi

step "恢复演练：解包到独立 drill 卷"
DRILL_VOL="orgflow-devops_nexus_drill_$(date +%Y%m%d%H%M%S)_$$"
docker volume create "$DRILL_VOL" >/dev/null
log "  drill 卷: $DRILL_VOL（与生产卷 orgflow-devops_nexus_data 无关）"
# 归档必须经 stdin 投递，不能 bind mount 它的目录：Jenkins agent 里跑时，
# agent 与宿主是两个文件系统（agent 用宿主的 docker.sock），
# `-v <agent里的目录>:/backup:ro` 会在宿主上找不到该路径。
# restore.sh 也是这么做的（tar xzpf - -C /data <"$FILE"）。
docker run --rm -i \
  -v "${DRILL_VOL}:/data" \
  alpine sh -c 'set -e; tar xzf - -C /data; chown -R 200:200 /data' <"$ARCHIVE"
DRILL_READY=1

DRILL_DB_SHA="$(docker run --rm -v "${DRILL_VOL}:/data:ro" alpine sha256sum /data/db/nexus.mv.db | cut -d' ' -f1)"
ARCH_DB_SHA="$(tar xzOf "$ARCHIVE" ./db/nexus.mv.db | sha256sum | cut -d' ' -f1)"
[ "$DRILL_DB_SHA" = "$ARCH_DB_SHA" ] ||
  fail "恢复后 db/nexus.mv.db 与归档内不一致（drill=$DRILL_DB_SHA arch=$ARCH_DB_SHA）"
log "  db/nexus.mv.db sha256 一致: ${DRILL_DB_SHA:0:16}…"

# busybox find 没有 -printf，用 -exec stat -c %s 取字节数（精确到文件，不含目录项）。
read -r DRILL_BLOB_FILES DRILL_BLOB_BYTES < <(
  docker run --rm -v "${DRILL_VOL}:/data:ro" alpine \
    sh -c "find /data/blobs -type f -exec stat -c %s {} + | awk '{n++; s+=\$1} END {print n+0, s+0}'"
)
[ "$DRILL_BLOB_FILES" = "$ARCH_BLOB_FILES" ] ||
  fail "恢复后 blob 文件数不一致（drill=$DRILL_BLOB_FILES arch=$ARCH_BLOB_FILES）"
[ "$DRILL_BLOB_BYTES" = "$ARCH_BLOB_BYTES" ] ||
  fail "恢复后 blob 总字节不一致（drill=$DRILL_BLOB_BYTES arch=$ARCH_BLOB_BYTES）"
log "  blobs 文件数/字节一致: ${DRILL_BLOB_FILES} 文件 / ${DRILL_BLOB_BYTES}B"

if [ "$BOOT_CHECK" = 0 ]; then
  step "跳过 boot check（--no-boot-check）"
  log "✓ 备份 + 内容校验 + 解包核对通过: $ARCHIVE"
  exit 0
fi

step "boot check：用 drill 卷起临时 Nexus，验证 H2 能真正打开"
if [ -z "$NEXUS_IMAGE" ]; then
  NEXUS_IMAGE="$(docker inspect "$NEXUS_CONTAINER" --format '{{.Config.Image}}' 2>/dev/null || true)"
fi
[ -n "$NEXUS_IMAGE" ] ||
  fail "无法确定 Nexus 镜像：设置 NEXUS_IMAGE 或保证 $NEXUS_CONTAINER 存在"
log "  镜像: $NEXUS_IMAGE（默认 bridge 网络，不接入 compose，不抢 nexus 别名）"
DRILL_CT="nexus-drill-$$"
docker run -d --name "$DRILL_CT" \
  -p 127.0.0.1::8081 \
  -v "${DRILL_VOL}:/nexus-data" \
  "$NEXUS_IMAGE" >/dev/null

waited=0
booted=0
while [ "$waited" -lt "$BOOT_TIMEOUT" ]; do
  # 不能用 `docker logs | grep -q`：grep 命中即退出会让 docker logs 吃 SIGPIPE，
  # 配合 pipefail 整条管道返回 141，判据会假阴性（这个坑在 LDAP 那轮踩过一次）。
  hits="$(docker logs "$DRILL_CT" 2>&1 | grep -c 'Started Sonatype Nexus' || true)"
  if [ "${hits:-0}" -gt 0 ]; then
    booted=1
    break
  fi
  if [ "$(docker inspect "$DRILL_CT" --format '{{.State.Running}}' 2>/dev/null || echo false)" != "true" ]; then
    echo "--- 容器已退出，最后 30 行日志 ---" >&2
    docker logs --tail 30 "$DRILL_CT" 2>&1 | sed 's/^/    /' >&2 || true
    fail "临时 Nexus 启动失败：恢复出来的数据库无法被打开"
  fi
  sleep 5
  waited=$((waited + 5))
done
[ "$booted" = 1 ] || fail "boot check 超时 ${BOOT_TIMEOUT}s：未出现 'Started Sonatype Nexus'"

PORT="$(docker port "$DRILL_CT" 8081/tcp | head -n1 | sed 's/.*://')"
CODE="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${PORT}/" || true)"
log "  Nexus 已启动（耗时约 ${waited}s），宿主端口 ${PORT}，HTTP ${CODE}"
case "$CODE" in
  200|401|403) ;;
  *) fail "boot check 的 HTTP 探测异常: ${CODE}" ;;
esac
log "✓ 恢复演练通过：H2 数据库可打开、blob store 完整、服务可启动"

step "结果"
log "  备份包: $ARCHIVE"
log "  db: ${ARCH_DB_BYTES}B · blobs: ${ARCH_BLOB_FILES} 文件 / ${ARCH_BLOB_BYTES}B"
log "  演练: db sha256 一致 · blob 数与字节一致 · 启动成功（HTTP ${CODE}）"
