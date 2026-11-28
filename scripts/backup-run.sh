#!/usr/bin/env bash
# backup-run.sh —— M3.0.4 T1：备份唯一入口（备份 + 校验 + 状态同源，原子写 status.json）
#
# 背景（F1/F2/F4）：M3.0.3 移除守护后，backup.sh 只产备份不写 status、不跑校验；
#   up.sh 补跑与 make backup 都不更新状态 → status 与 latest 断链，verify-backup 可能读旧状态假绿。
#   本脚本作为**唯一入口**：make backup 与 up.sh 启动补跑都调它，保证每次备份都伴随一次校验与一次原子状态写入。
#
# 流程：
#   1) 记录 start（UTC epoch + ISO8601）与 commit；
#   2) 调 scripts/backup.sh <ROOT> 生成备份（失败 → exit_code=1）；
#   3) 解析本轮 latest 实际目录，调 scripts/backup-verify.sh <dest> 校验（失败 → exit_code=7）；
#      ——verify 子进程通过 BACKUP_VERIFY_NO_STATUS=1 跳过它自己的 status 写入，由本脚本统一原子写。
#   4) 一次性原子写 /data/backups/status.json：
#      backup(绝对路径)/backup_ts/exit_code/verify/bytes/volumes/commit/duration_sec/finished_at
#      （兼容保留 last_start/last_end/retention/disk_used_pct/updated_at 等旧字段）；
#   5) 退出码即结果（0 成功 / 1 备份失败 / 7 校验失败）。
#
# 用法: bash scripts/backup-run.sh [目标根目录]（默认 ${BACKUP_ROOT:-/data/backups}）
set -uo pipefail

ROOT="${1:-${BACKUP_ROOT:-/data/backups}}"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATUS="$ROOT/status.json"
START_EPOCH="$(date -u +%s)"
START="$(date -u -d "@$START_EPOCH" '+%Y-%m-%dT%H:%M:%SZ')"
COMMIT="$(git -C "$REPO" rev-parse HEAD 2>/dev/null || echo unknown)"

mkdir -p "$ROOT"

# ---- 原子写 status.json（唯一写入点）----
# 参数: exit_code verify_json backup_abs backup_ts bytes volumes
write_status() {
  local ec="$1" verify="$2" backup="$3" bts="$4" bytes="$5" volumes="$6"
  local finished; finished="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  local end_epoch; end_epoch="$(date -u -d "$finished" +%s)"
  local dur=$(( end_epoch - START_EPOCH ))
  [ "$dur" -ge 0 ] || dur=0
  python3 - "$STATUS" "$ec" "$verify" "$backup" "$bts" "$bytes" "$volumes" "$COMMIT" "$dur" "$finished" "$START" <<'PY'
import json, sys, os
(p, ec, verify, backup, bts, bytes_, volumes, commit, dur, finished, start) = sys.argv[1:12]
try:
    old = json.load(open(p, encoding='utf-8'))
except Exception:
    old = {}
try:
    v = json.loads(verify)
except Exception:
    v = {"ok": False, "failures": ["verify-field-unreadable"]}
d = dict(old)
d.update({
    "backup": backup,
    "backup_ts": bts,
    "last_start": start,
    "last_end": finished,
    "finished_at": finished,
    "exit_code": int(ec),
    "verify": v,
    "bytes": int(bytes_ or 0),
    "volumes": int(volumes or 0),
    "commit": commit,
    "duration_sec": int(dur),
    "updated_at": finished,
})
d.setdefault("retention", {"daily": 7, "weekly": 4})
d.setdefault("disk_used_pct", 0)
d.pop("next_run", None)  # M3.0.4：无常驻调度，不再写下次运行时刻
tmp = p + ".tmp"
with open(tmp, 'w', encoding='utf-8') as f:
    json.dump(d, f, ensure_ascii=False, indent=2)
os.replace(tmp, p)
print("[backup-run] status.json 已原子写: exit_code=%s backup=%s verify.ok=%s finished_at=%s" % (
    ec, backup, v.get('ok'), finished))
PY
}

# ---- 1) 调 backup.sh 生成备份 ----
echo "[backup-run] start=$START commit=$COMMIT"
BRC=0
BACKUP_ROOT="$ROOT" bash "$REPO/scripts/backup.sh" "$ROOT" || BRC=$?

# 解析本轮 latest 实际目录（绝对路径）与 backup_ts（目录名）
DEST="$(cat "$ROOT/latest" 2>/dev/null || true)"
BT="$(basename "$DEST" 2>/dev/null || true)"
[ -n "$DEST" ] || DEST="unknown"
[ -n "$BT" ] || BT="unknown"

# 收集 bytes/volumes（从 manifest，写到临时文件再读，避免 eval/heredoc 在此环境丢输出）
BYTES=0; VOLUMES=0
if [ -n "$DEST" ] && [ -f "$DEST/manifest.json" ]; then
  python3 - "$DEST/manifest.json" /tmp/backup-run.meta <<'PY' 2>/dev/null
import json,sys,os
m=json.load(open(sys.argv[1],encoding='utf-8'))
d=os.path.dirname(sys.argv[1])
tot=sum(os.path.getsize(os.path.join(d,e['archive'])) for e in m.get('volumes',[]) if os.path.exists(os.path.join(d,e['archive'])))
open(sys.argv[2],'w').write("bytes=%d volumes=%d" % (tot, m.get('total_volumes', len(m.get('volumes',[])))))
PY
  if [ -f /tmp/backup-run.meta ]; then
    BYTES="$(grep -oE 'bytes=[0-9]+' /tmp/backup-run.meta | cut -d= -f2)"
    VOLUMES="$(grep -oE 'volumes=[0-9]+' /tmp/backup-run.meta | cut -d= -f2)"
    rm -f /tmp/backup-run.meta
  fi
  : "${BYTES:=0}"; : "${VOLUMES:=0}"
fi

# ---- 2) 备份失败 → exit_code=1，写状态后退出 ----
if [ "$BRC" -ne 0 ] || [ ! -f "$DEST/manifest.json" ]; then
  echo "✗ [backup-run] 备份失败 rc=$BRC dest=$DEST（exit_code=1）" >&2
  write_status 1 '{"ok":false,"failures":["backup-failed"]}' "$DEST" "$BT" "$BYTES" "$VOLUMES"
  exit 1
fi

# ---- 3) 调 backup-verify.sh 校验（跳过其自身 status 写入）----
# m3.0.5 T5（D5）：透传 BACKUP_ROOT="$ROOT"，使 verify 的临时状态文件 <ROOT>/status.json.verify.tmp
#   落在与备份同一根目录，自定义 BACKUP_ROOT 时 verify.ok 不再读到 /data/backups 的陈旧文件而误判红。
VRC=0
BACKUP_ROOT="$ROOT" BACKUP_VERIFY_NO_STATUS=1 bash "$REPO/scripts/backup-verify.sh" "$DEST" || VRC=$?
VERIFY_JSON="$(python3 - "$ROOT/status.json" "$VRC" <<'PY' 2>/dev/null
import json,sys
p, vrc = sys.argv[1], int(sys.argv[2])
v = {"ok": False, "failures": []}
# backup-verify 在 NO_STATUS 模式下把完整结果写到 <status>.verify.tmp：结构为 {"verify":{ok,checked_at,failures}}
try:
    t=json.load(open(p+'.verify.tmp',encoding='utf-8'))
    if isinstance(t,dict):
        v = dict(t.get('verify', t))  # 取 .verify 子对象（若已是裸对象则直接用）
except Exception:
    pass
v.setdefault('failures', [])
v['ok'] = (vrc == 0 and v.get('ok', True) is True)
if vrc != 0 and not any('verify-rc' in str(f) for f in v.get('failures',[])):
    v['failures'].append('verify-rc-nonzero')
print(json.dumps(v,ensure_ascii=False))
PY
)"
rm -f "$ROOT/status.json.verify.tmp" "$ROOT/status.json.verify.tmp.tmp"
[ -n "$VERIFY_JSON" ] || VERIFY_JSON="{\"ok\":false,\"failures\":[\"verify-field-unreadable\"]}"

# ---- 4) 校验失败 → exit_code=7；成功 → 0；统一原子写状态 ----
if [ "$VRC" -ne 0 ]; then
  echo "✗ [backup-run] 校验失败 rc=$VRC dest=$DEST（exit_code=7，保留现场）" >&2
  write_status 7 "$VERIFY_JSON" "$DEST" "$BT" "$BYTES" "$VOLUMES"
  exit 7
fi

write_status 0 "$VERIFY_JSON" "$DEST" "$BT" "$BYTES" "$VOLUMES"
echo "✓ [backup-run] 备份+校验完成 exit_code=0 dest=$DEST bytes=$BYTES volumes=$VOLUMES"
exit 0
