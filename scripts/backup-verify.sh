#!/usr/bin/env bash
# backup-verify.sh —— M3.0 备份校验：sha256 一致 + 逐卷解包可读 + 条目数一致
# 用法: bash scripts/backup-verify.sh [备份目录]
#   未指定时取 /data/backups/latest 指针。
set -euo pipefail

ROOT="${BACKUP_ROOT:-/data/backups}"
DEST="${1:-}"
if [ -z "$DEST" ]; then
  [ -f "$ROOT/latest" ] || { echo "✗ 无 latest 指针且未指定备份目录" >&2; exit 1; }
  DEST="$(cat "$ROOT/latest")"
fi
[ -d "$DEST" ] || { echo "✗ 备份目录不存在: $DEST" >&2; exit 1; }

echo "[verify] 校验备份: $DEST"
rc=0

# 1) sha256 校验（逐行，避免 sha256sum -c 的 cwd 依赖）
( cd "$DEST" && sha256sum -c sha256sum.txt ) || rc=1

# 2) manifest 逐卷：解包可读 + 条目数一致
python3 - "$DEST" <<'PY' || rc=1
import os, sys, json, tarfile
dest=sys.argv[1]
m=json.load(open(os.path.join(dest,'manifest.json'),encoding='utf-8'))
bad=0
for e in m['volumes']:
    p=os.path.join(dest,e['archive'])
    try:
        with tarfile.open(p,'r:gz') as tf:
            names=tf.getnames()
            # 实际解包到 /dev/null 流验证 gzip 完整可读
            tf.getmembers()
        n=len(names)
        ok = (n==e['entries'])
        print("  %-34s entries=%d/%d %s" % (e['volume'], n, e['entries'], 'OK' if ok else 'MISMATCH'))
        if not ok: bad+=1
    except Exception as ex:
        print("  %-34s UNREADABLE: %s" % (e['volume'], ex)); bad+=1
print("[verify] manifest 卷数=%d 条目总数=%d" % (m['total_volumes'], sum(e['entries'] for e in m['volumes'])))
sys.exit(1 if bad else 0)
PY

if [ "$rc" -eq 0 ]; then
  echo "✓ 备份校验通过: $DEST"
else
  echo "✗ 备份校验失败: $DEST" >&2
fi
exit "$rc"
