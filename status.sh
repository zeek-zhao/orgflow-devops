#!/usr/bin/env bash
# status.sh —— M0-v2 只读查看各服务状态（表格/JSON；--render 先渲染首页再查）
# T3：新增 FP 列 —— match(指纹一致) / stale(配置或镜像已变、容器仍旧) / baseline(存量容器无指纹) / absent
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"
JSON=0; RENDER=0; PREFIX="${CONTAINER_PREFIX:-of}"
for a in "$@"; do
  case "$a" in
    --json) JSON=1 ;;
    --render) RENDER=1 ;;
    -h|--help) echo "用法: status.sh [--json] [--render]"; exit 0 ;;
  esac
done
if (( RENDER )); then python3.11 scripts/render-homepage.py >/dev/null; fi
mapfile -t ORDER < <(python3.11 -c "import csv; [print(r['service']) for r in csv.DictReader(open('services/manifest.tsv',encoding='utf-8-sig'),delimiter='\t')]")

ENVFILE="${ENV_FILE:-config/defaults.env}"
img_of() { grep -E "^IMAGE_$(echo "$1"|tr 'a-z-' 'A-Z_')=" config/images.env 2>/dev/null | head -1 | cut -d= -f2-; }
fingerprint() {
  local svc="$1" img iid
  img="$(img_of "$svc")"
  iid="$(docker image inspect "${img:-none}" --format '{{.Id}}' 2>/dev/null || echo "${img:-none}")"
  { cat "services/$svc/compose.yml" "$ENVFILE"; echo "IMAGE=$img"; echo "IID=$iid"; } 2>/dev/null | sha256sum | awk '{print $1}'
}
fp_status() {
  local svc="$1" cid want have
  cid="$(docker ps -aq -f "name=^${PREFIX}-${svc}\$" 2>/dev/null | head -1)"
  [[ -n "$cid" ]] || { echo "absent"; return; }
  have="$(docker inspect -f '{{index .Config.Labels "org.of.fp"}}' "$cid" 2>/dev/null | grep -v '^<no value>$' || true)"
  [[ -z "$have" ]] && { echo "baseline"; return; }
  want="$(fingerprint "$svc")"
  [[ "$have" == "$want" ]] && echo "match" || echo "stale"
}

(( JSON )) || printf '%-13s %-12s %-12s %-9s %-20s %s\n' SERVICE STATUS HEALTH FP PORTS STARTED
rc=0
for svc in "${ORDER[@]}"; do
  cid="$(docker ps -aq -f "name=^${PREFIX}-${svc}\$" 2>/dev/null | head -1)"
  if [[ -z "$cid" ]]; then
    st="absent"; health="-"; ports="-"; started="-"; fp="absent"
  else
    st="$(docker inspect -f '{{.State.Status}}' "$cid" 2>/dev/null)"
    health="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}-{{end}}' "$cid" 2>/dev/null)"
    ports="$(docker inspect -f '{{range $p,$v := .NetworkSettings.Ports}}{{$p}} {{end}}' "$cid" 2>/dev/null | tr -s ' ' | cut -c1-18)"
    started="$(docker inspect -f '{{.State.StartedAt}}' "$cid" 2>/dev/null | cut -c1-19)"
    fp="$(fp_status "$svc")"
    [[ "$st" == "exited" ]] && st="exited($(docker inspect -f '{{.State.ExitCode}}' "$cid" 2>/dev/null))"
  fi
  if (( JSON )); then
    python3.11 -c "import json;print(json.dumps({'service':'$svc','status':'$st','health':'$health','fp':'$fp','started':'$started'},ensure_ascii=False))"
  else
    printf '%-13s %-12s %-12s %-9s %-20s %s\n' "$svc" "$st" "$health" "$fp" "$ports" "$started"
  fi
  case "$st" in healthy|exited\(0\)) ;; *) rc=1 ;; esac
done
exit $rc
