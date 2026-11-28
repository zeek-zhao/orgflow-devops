#!/usr/bin/env bash
# backup.sh —— M3.0 卷级备份（tar + sha256sum + manifest），不引入新组件
# 用法: bash scripts/backup.sh [目标根目录]
#   目标根目录默认 /data/backups（M3.0 开工决定：本机第二路径）
# 产出: <root>/<UTC>/ 下含 <vol>.tar.gz、sha256sum.txt、manifest.json
# 特性: 幂等可重复执行；每卷先打包再校验和解包可读性；任一失败即非零退出。
set -euo pipefail

ROOT="${1:-${BACKUP_ROOT:-/data/backups}}"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TS="$(date -u +%Y%m%dT%H%M%SZ)"
DEST="$ROOT/$TS"

# 必备卷（M3.0 文档清单；builder_cache 可再生不备份）
VOLS=(
  orgflow-minimal_jenkins_home
  orgflow-minimal_registry_data
  orgflow-minimal_gerrit_git
  orgflow-minimal_gerrit_etc
  orgflow-minimal_ldap_data
  orgflow-minimal_ldap_config
  orgflow-minimal_selfcheck_reports
  orgflow-minimal_ca-data
  orgflow-minimal_registry_auth
)

mkdir -p "$DEST"
# M3.0.1 T1: 打包窗口内变更文件计数表 + tar 告警日志
CHANGED_TSV="$DEST/.changed.tsv"
LOG_TAR="$DEST/.tar-warnings.log"
: > "$CHANGED_TSV"; : > "$LOG_TAR"
echo "[backup] 目标: $DEST"
echo "[backup] commit: $(git -C "$REPO" rev-parse HEAD)"

# 1) 逐卷打包（直接从 volume mountpoint tar，避免额外容器/组件）
for vol in "${VOLS[@]}"; do
  mp="$(docker volume inspect "$vol" --format '{{.Mountpoint}}' 2>/dev/null || true)"
  if [ -z "$mp" ] || [ ! -d "$mp" ]; then
    echo "✗ 卷 $vol 不存在或无 mountpoint" >&2
    exit 1
  fi
  echo "[backup] 打包 $vol <- $mp"
  # M3.0.1 T1: 记录打包窗口内被修改文件数（find -newermt 起始时间），写 manifest 的 changed_during_backup。
  tfile="$(mktemp)"
  : > "$tfile"
  changed=0
  # tar 加 --warning=no-file-changed；退出码 1（文件在打包期间变化）时对该卷重试一次，
  # 仍失败则整轮失败。重试前刷新时间戳标记。
  rc=0
  tar --warning=no-file-changed -czf "$DEST/$vol.tar.gz" -C "$mp" . 2>>"$LOG_TAR" || rc=$?
  if [ "$rc" -eq 1 ]; then
    echo "[backup] ⚠ $vol tar 退出码=1（文件变化），重试一次" >&2
    : > "$tfile"
    tar --warning=no-file-changed -czf "$DEST/$vol.tar.gz" -C "$mp" . 2>>"$LOG_TAR" || rc=$?
  fi
  if [ "$rc" -ne 0 ]; then
    echo "✗ 卷 $vol 打包失败（rc=$rc）" >&2
    rm -f "$tfile"
    exit 1
  fi
  changed="$(find "$mp" -newer "$tfile" -type f 2>/dev/null | wc -l)"
  printf '%s\t%s\n' "$vol" "$changed" >> "$CHANGED_TSV"
  rm -f "$tfile"
done

# 2) sha256 清单
( cd "$DEST" && sha256sum ./*.tar.gz > sha256sum.txt )

# 3) manifest.json（卷名/大小/条目数/时间/commit/镜像 tag 快照）
COMMIT="$(git -C "$REPO" rev-parse HEAD)"
python3 - "$DEST" "$COMMIT" "$TS" "$REPO" "${VOLS[@]}" <<'PY'
import os, sys, json, tarfile
dest, commit, ts, repo, vols = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5:]
def img_snapshot(repo):
    d={}
    p=os.path.join(repo,'config','images.env')
    if os.path.exists(p):
        for line in open(p,encoding='utf-8'):
            line=line.strip()
            if line.startswith('IMAGE_') and '=' in line:
                k,v=line.split('=',1); d[k]=v
    return d
# M3.0.1 T1: 读取打包窗口变更文件数
changed={}
ct=os.path.join(dest,'.changed.tsv')
if os.path.exists(ct):
    for line in open(ct,encoding='utf-8'):
        parts=line.rstrip('\n').split('\t')
        if len(parts)==2: changed[parts[0]]=int(parts[1])
entries=[]
for v in vols:
    tgz=os.path.join(dest, v+'.tar.gz')
    with tarfile.open(tgz,'r:gz') as tf:
        n=len(tf.getnames())
    entries.append({
        "volume": v,
        "archive": v+'.tar.gz',
        "bytes": os.path.getsize(tgz),
        "entries": n,
        "changed_during_backup": changed.get(v, 0),
    })
m={
    "created_utc": ts,
    "commit": commit,
    "image_tags": img_snapshot(repo),
    "volumes": entries,
    "total_volumes": len(entries),
}
with open(os.path.join(dest,'manifest.json'),'w',encoding='utf-8') as f:
    json.dump(m,f,ensure_ascii=False,indent=2)
# 清理中间文件（不进交付产物）
for tmp in ('.changed.tsv','.tar-warnings.log'):
    p=os.path.join(dest,tmp)
    if os.path.exists(p): os.remove(p)
print("[backup] manifest: %d 卷, %d 条目 (changed_during_backup 已记录)" % (len(entries), sum(e['entries'] for e in entries)))
PY

# 4) 交付指针
printf '%s' "$DEST" > "$ROOT/latest"

echo "✓ 备份完成: $DEST"
echo "  下次验收: make backup-verify BACKUP=$DEST"
