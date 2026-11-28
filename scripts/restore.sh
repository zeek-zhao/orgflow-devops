#!/usr/bin/env bash
# restore.sh —— M3.0 隔离恢复演练：从备份解包到隔离目录，逐一比对对象计数/名单
# 用法: bash scripts/restore.sh BACKUP=<备份目录> [PROJECT=orgflow-drill] [VERIFY=1]
#   VERIFY=1（默认）会同时读取生产卷，做"数量 + 关键对象名单"逐项比对。
#   本脚本只读生产卷，不启停任何容器，不改变生产数据；恢复产物落 /data/drill/<project>/。
#   真正起 drill 栈（独立网络+偏移端口）见 docs/运维/备份与恢复.md 的可选步骤。
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# 同时支持三种传参：环境变量 BACKUP=...、位置参数 "BACKUP=..."、位置参数纯路径
_argv1="${1:-}"
_argv2="${2:-}"
BACKUP="${BACKUP:-}"
PROJECT="${PROJECT:-orgflow-drill}"
VERIFY="${VERIFY:-1}"
ROOT="${BACKUP_ROOT:-/data/backups}"
case "$_argv1" in
  BACKUP=*) BACKUP="${_argv1#BACKUP=}" ;;
  PROJECT=*) PROJECT="${_argv1#PROJECT=}" ;;
  VERIFY=*) VERIFY="${_argv1#VERIFY=}" ;;
  "") ;;
  *) BACKUP="$_argv1" ;;   # 纯路径
esac
case "$_argv2" in
  PROJECT=*) PROJECT="${_argv2#PROJECT=}" ;;
  BACKUP=*) BACKUP="${_argv2#BACKUP=}" ;;
  "") ;;
  *) ;;
esac

if [ -z "$BACKUP" ]; then
  [ -f "$ROOT/latest" ] && BACKUP="$(cat "$ROOT/latest")" || { echo "✗ 需指定 BACKUP=<目录>" >&2; exit 1; }
fi
[ -d "$BACKUP" ] || { echo "✗ 备份目录不存在: $BACKUP" >&2; exit 1; }
[ -f "$BACKUP/manifest.json" ] || { echo "✗ 缺 manifest.json" >&2; exit 1; }

DRILL="/data/drill/$PROJECT"
mkdir -p "$DRILL"
echo "[restore] 备份: $BACKUP"
echo "[restore] 隔离目录: $DRILL"

# 1) 逐卷解包到隔离目录
python3 - "$BACKUP" "$DRILL" <<'PY'
import os, sys, json, tarfile
backup, drill=sys.argv[1], sys.argv[2]
m=json.load(open(os.path.join(backup,'manifest.json'),encoding='utf-8'))
for e in m['volumes']:
    v=e['volume']; short=v.replace('orgflow-minimal_','')
    dest=os.path.join(drill,short); os.makedirs(dest,exist_ok=True)
    with tarfile.open(os.path.join(backup,e['archive']),'r:gz') as tf:
        tf.extractall(dest)
    print("  [restore] %s -> %s" % (v,dest))
PY

# 2) 对象计数 + 名单（隔离恢复侧）
count_objects() {  # $1=根
  local root="$1"
  local gg="$root/gerrit_git" rd="$root/registry_data" jh="$root/jenkins_home"
  echo "GERRIT_REPOS=$(find "$gg" -maxdepth 2 -name '*.git' -type d 2>/dev/null | wc -l)"
  echo "REGISTRY_DIGESTS=$(find "$rd/docker/registry/v2/repositories" -path '*/_manifests/revisions/sha256/*' -name link -type f 2>/dev/null | wc -l)"
  echo "JENKINS_JOBS=$(find "$jh/jobs" -name config.xml -type f 2>/dev/null | wc -l)"
}
echo "[restore] 隔离侧对象计数:"
count_objects "$DRILL"

# 3) 与生产卷逐项比对（数量 + 名单）
if [ "$VERIFY" = "1" ]; then
  python3 - "$DRILL" <<'PY'
import os, sys, subprocess
drill=sys.argv[1]
PROD='/ags/workbuddy-data/docker-main/volumes'
def gp(name): return os.path.join(PROD,'orgflow-minimal_'+name,'_data')
def repos(g):
    return sorted(os.path.basename(p) for p in os.listdir(g) if p.endswith('.git')) if os.path.isdir(g) else []
def digests(rd):
    r=os.path.join(rd,'docker','registry','v2','repositories')
    out=[]
    if os.path.isdir(r):
        for dp,_,fs in os.walk(r):
            if '/_manifests/revisions/sha256/' in dp.replace('\\','/') and 'link' in fs:
                out.append(os.path.basename(dp.rstrip('/')))  # digest 值
    return sorted(out)
def jobs(jh):
    j=os.path.join(jh,'jobs')
    out=[]
    if os.path.isdir(j):
        for dp,_,fs in os.walk(j):
            if 'config.xml' in fs:
                out.append(os.path.relpath(dp,j))
    return sorted(out)

# 生产：各卷自身根；恢复：drill 下的同名子目录
prod={'gerrit_git':gp('gerrit_git'),'registry_data':gp('registry_data'),'jenkins_home':gp('jenkins_home')}
rec={'gerrit_git':os.path.join(drill,'gerrit_git'),'registry_data':os.path.join(drill,'registry_data'),'jenkins_home':os.path.join(drill,'jenkins_home')}
checks=[('Gerrit 仓库',repos,'gerrit_git'),('Registry digest',digests,'registry_data'),('Jenkins Job',jobs,'jenkins_home')]
bad=0
for name,fn,key in checks:
    a=fn(prod[key]); b=fn(rec[key])
    ok=(a==b)
    print("  [%s] 生产=%d 恢复=%d 名单一致=%s" % (name,len(a),len(b),'YES' if ok else 'NO'))
    if not ok:
        bad+=1
        print("    仅生产:", sorted(set(a)-set(b))[:10])
        print("    仅恢复:", sorted(set(b)-set(a))[:10])
print("[restore] 逐项比对:", "全部一致 ✓" if bad==0 else ("%d 项不一致 ✗"%bad))
raise SystemExit(1 if bad else 0)
PY
fi

echo "✓ 隔离恢复演练完成（隔离数据保留在 $DRILL，未动生产）"
