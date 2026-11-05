#!/usr/bin/env bash
# collect-jenkins-warnings.sh —— 只读抓取 Manage Jenkins 的警告列表（REQ-M0-B3 / #92）
#
# 在 213 上运行，需要 docker 与主仓库 .env（默认 ~/workbuddy/orgflow-devops/.env）。
# 用法：
#   bash scripts/collect-jenkins-warnings.sh                 # 规范化警告清单打印到 stdout
#   bash scripts/collect-jenkins-warnings.sh --save FILE    # 同时把清单写入 FILE（快照）
#   bash scripts/collect-jenkins-warnings.sh --env-file P   # 指定 .env
#   bash scripts/collect-jenkins-warnings.sh --container C  # 指定容器名（默认 of-jenkins）
#
# 只读：只发 GET，不改 Jenkins 任何状态，凭据只从 .env 读入且不打印。
# 抓取方式：docker exec of-jenkins curl http://localhost:8080/manage/（容器内直连）。
#   任务建议的两个端点都抓；本 Jenkins 版本 /administrativeMonitor/ 返回 404，
#   实际警告以 /manage/ 页面里可见的 app-adminmonitor 区块 + 独立 JCasC alert 为准。
#   网关方式 https://jenkins.<domain>/manage/ 被 oauth2-proxy 拦成 302，取不到页面。
#
# 输出列：编号<TAB>运行时标识<TAB>级别<TAB>现象（截断 300 字）。
# 未在已知映射里的新警告编号为 W-UNREGISTERED —— 台账核对脚本会据此报「未登记」。

set -euo pipefail

ENV_FILE="${ENV_FILE:-$HOME/workbuddy/orgflow-devops/.env}"
CONTAINER="${JENKINS_CONTAINER:-of-jenkins}"
SAVE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --save) SAVE="$2"; shift 2 ;;
    --env-file) ENV_FILE="$2"; shift 2 ;;
    --container) CONTAINER="$2"; shift 2 ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

if [ ! -r "$ENV_FILE" ]; then echo "env file not readable: $ENV_FILE" >&2; exit 2; fi
set -a
. "$ENV_FILE"
set +a
: "${JENKINS_ADMIN_ID:?missing JENKINS_ADMIN_ID}"
: "${JENKINS_ADMIN_PASSWORD:?missing JENKINS_ADMIN_PASSWORD}"

if ! docker ps --format '{{.Names}}' | grep -qx "$CONTAINER"; then
  echo "container not running: $CONTAINER" >&2; exit 2
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# 两个端点：HTTP 码/大小走 stderr（原样取证），HTML 落文件。
docker exec -e JID="$JENKINS_ADMIN_ID" -e JPW="$JENKINS_ADMIN_PASSWORD" "$CONTAINER" sh -c '
  curl -sS -o /tmp/w-manage.html -w "GET /manage/ -> HTTP=%{http_code} size=%{size_download}\n" \
    -u "$JID:$JPW" http://localhost:8080/manage/
  curl -sS -o /tmp/w-mon.html -w "GET /administrativeMonitor/ -> HTTP=%{http_code} size=%{size_download}\n" \
    -u "$JID:$JPW" http://localhost:8080/administrativeMonitor/
' >&2
docker exec "$CONTAINER" cat /tmp/w-manage.html > "$TMP/manage.html"

python3 - "$TMP/manage.html" > "$TMP/normalized.txt" <<'__PY__'
import re, sys, html as H
s = open(sys.argv[1], encoding='utf-8', errors='replace').read()
# 台账编号 <-> 运行时标识。新增/未知警告一律 W-UNREGISTERED。
MAP = {
    'jenkins.casc.obsolete.git': 'W-01',
    'jenkins.diagnostics.ControllerExecutorsAgents': 'W-02',
    'jenkins.monitor.JavaVersionRecommendationAdminMonitor-21-2027-09-30-WARNING': 'W-03',
    'jenkins.security.csp.impl.CspRecommendation': 'W-04',
}
anchors = []
for m in re.finditer(r'<div data-monitor-id="([^"]+)"[^>]*class="app-adminmonitor ([^"]*)"', s):
    if 'jenkins-hidden' in m.group(2):
        continue  # 未激活的占位不算当前警告
    anchors.append((m.start(), m.group(1), m.group(2)))
for m in re.finditer(r'<div class="alert alert-warning">', s):
    if 'Configuration as Code obsolete file format' in s[m.start():m.start()+500]:
        anchors.append((m.start(), 'jenkins.casc.obsolete.git', 'alert-warning'))
anchors.sort()

def clean(seg):
    for p in (r'<script.*?</script>', r'<svg.*?</svg>', r'<style.*?</style>'):
        seg = re.sub(p, ' ', seg, flags=re.S)
    return re.sub(r'\s+', ' ', H.unescape(re.sub(r'<[^>]+>', ' ', seg))).strip()

for i, (pos, mid, cls) in enumerate(anchors):
    end = anchors[i+1][0] if i+1 < len(anchors) else min(len(s), pos+6000)
    txt = re.sub(r'^(More Info|Learn more|Manage)\s+', '', clean(s[pos:end])).strip()
    level = 'warning' if 'warning' in cls else 'info' if 'info' in cls else 'warning'
    print(f'{MAP.get(mid, "W-UNREGISTERED")}\t{mid}\t{level}\t{txt[:300]}')
__PY__

cat "$TMP/normalized.txt"
if [ -n "$SAVE" ]; then
  cp "$TMP/normalized.txt" "$SAVE"
  echo "saved snapshot: $SAVE" >&2
fi
