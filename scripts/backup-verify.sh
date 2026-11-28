#!/usr/bin/env bash
# backup-verify.sh —— 备份校验：sha256 一致 + 逐卷解包可读 + 条目数一致 + 热备一致性（M3.0.1 T5）
#   T5 新增三类校验：
#     a) gerrit_git 下每个 *.git 跑 git fsck --no-dangling，任何 error 即 FAIL；
#     b) jenkins_home/config.xml 与 jobs/*/config.xml 用 xml.etree 解析，失败即 FAIL；
#     c) 校验结果写 /data/backups/status.json 的 verify 字段（ok/checked_at/failures）。
# 用法: bash scripts/backup-verify.sh [备份目录]
#   未指定时取 /data/backups/latest 指针。
set -uo pipefail

ROOT="${BACKUP_ROOT:-/data/backups}"
DEST="${1:-}"
if [ -z "$DEST" ]; then
  [ -f "$ROOT/latest" ] || { echo "✗ 无 latest 指针且未指定备份目录" >&2; exit 1; }
  DEST="$(cat "$ROOT/latest")"
fi
[ -d "$DEST" ] || { echo "✗ 备份目录不存在: $DEST" >&2; exit 1; }

echo "[verify] 校验备份: $DEST"
rc=0
failures=()

# 1) sha256 校验（逐行，避免 sha256sum -c 的 cwd 依赖）
( cd "$DEST" && sha256sum -c sha256sum.txt ) || { rc=1; failures+=("sha256sum"); }

# 2) manifest 逐卷：解包可读 + 条目数一致
python3 - "$DEST" <<'PY' || { rc=1; failures+=("manifest-entries"); }
import os, sys, json, tarfile
dest=sys.argv[1]
m=json.load(open(os.path.join(dest,'manifest.json'),encoding='utf-8'))
bad=0
for e in m['volumes']:
    p=os.path.join(dest,e['archive'])
    try:
        with tarfile.open(p,'r:gz') as tf:
            names=tf.getnames()
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

# 3) T5-a: gerrit_git 逐仓库 git fsck --no-dangling
TMP="$(mktemp -d /tmp/bkverify.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/gerrit_git" "$TMP/jenkins_home"
tar -xzf "$DEST/orgflow-minimal_gerrit_git.tar.gz" -C "$TMP/gerrit_git" 2>/dev/null || { rc=1; failures+=("gerrit-untar"); }
tar -xzf "$DEST/orgflow-minimal_jenkins_home.tar.gz" -C "$TMP/jenkins_home" 2>/dev/null || { rc=1; failures+=("jenkins-untar"); }

git_count=0; git_bad=0
# Gerrit 系统仓库 All-Projects.git / All-Users.git 的 HEAD 设计上指向 refs/meta/config，
# git fsck 会报 "HEAD points to something strange" 并让 rc=8，属误报，白名单过滤。
# 真实损坏（pack does not match index / invalid sha1 / missing object 等）必须判 FAIL。
while IFS= read -r repo; do
  git_count=$((git_count+1))
  out="$(git --git-dir="$repo" fsck --no-dangling 2>&1)"
  errs="$(printf '%s' "$out" | grep -iE '(^| )(error|missing|corrupt|broken|bad|invalid|does not match)' \
          | grep -viE 'HEAD points to something strange' || true)"
  printf '  [git fsck] %s %s\n' "$(basename "$repo")" "$(printf '%s' "$out" | tr '\n' ' ' | head -c 200)"
  if [ -n "$errs" ]; then
    git_bad=$((git_bad+1))
    printf '  [git fsck] %s 检出异常: %s\n' "$(basename "$repo")" "$(printf '%s' "$errs" | head -1)"
  fi
done < <(find "$TMP/gerrit_git" -type d -name '*.git' 2>/dev/null)
echo "[verify] git fsck: 仓库=$git_count 异常=$git_bad"
[ "$git_bad" -eq 0 ] || { rc=1; failures+=("git-fsck"); }

# 4) T5-b: Jenkins XML 解析（config.xml + jobs/*/config.xml）
python3 - "$TMP/jenkins_home" <<'PY' || { rc=1; failures+=("jenkins-xml"); }
import os, sys, xml.etree.ElementTree as ET
root=sys.argv[1]
files=[os.path.join(root,'config.xml')]
jobs=os.path.join(root,'jobs')
if os.path.isdir(jobs):
    for dp,_,fs in os.walk(jobs):
        for f in fs:
            if f=='config.xml': files.append(os.path.join(dp,f))
bad=0
for p in files:
    try: ET.parse(p)
    except Exception as ex:
        print("  [xml] %s PARSE FAIL: %s" % (os.path.relpath(p,root), ex)); bad+=1
print("[verify] jenkins xml: 文件=%d 解析失败=%d" % (len(files),bad))
sys.exit(1 if bad else 0)
PY

# 5) T5-c: 写 status.json 的 verify 字段（ok/checked_at/failures）
python3 - "$ROOT/status.json" "$rc" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "${failures[@]+${failures[@]}}" <<'PY' || true
import json,sys,os
p=sys.argv[1]; rc=sys.argv[2]; ts=sys.argv[3]; fails=sys.argv[4:]
try: d=json.load(open(p,encoding='utf-8'))
except Exception: d={}
d['verify']={"ok": (rc=='0'), "checked_at": ts, "failures": [f for f in fails if f]}
tmp=p+'.tmp'; json.dump(d,open(tmp,'w',encoding='utf-8'),ensure_ascii=False,indent=2); os.replace(tmp,p)
print("[verify] status.json.verify.ok=%s failures=%s" % (rc=='0', d['verify']['failures']))
PY

if [ "$rc" -eq 0 ]; then
  echo "✓ 备份校验通过: $DEST"
else
  echo "✗ 备份校验失败: $DEST（failures: ${failures[*]:-?}）" >&2
fi
exit "$rc"
