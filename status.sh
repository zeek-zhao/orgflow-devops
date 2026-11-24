#!/usr/bin/env bash
# status.sh —— M0-v2 只读查看各服务状态（表格/JSON；--render 先渲染首页再查）
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"
JSON=0; RENDER=0
for a in "$@"; do
  case "$a" in
    --json) JSON=1 ;;
    --render) RENDER=1 ;;
    -h|--help) echo "用法: status.sh [--json] [--render]"; exit 0 ;;
  esac
done
if (( RENDER )); then python3.11 scripts/render-homepage.py >/dev/null; fi
mapfile -t ORDER < <(python3.11 -c "import csv; [print(r['service']) for r in csv.DictReader(open('services/manifest.tsv',encoding='utf-8-sig'),delimiter='\t')]")
(( JSON )) || printf '%-13s %-14s %-14s %-20s %s\n' SERVICE STATUS HEALTH PORTS STARTED
rc=0
for svc in "${ORDER[@]}"; do
  cid="$(docker ps -aq -f "name=^of-${svc}\$" 2>/dev/null | head -1)"
  if [[ -z "$cid" ]]; then
    st="absent"; health="-"; ports="-"; started="-"
  else
    st="$(docker inspect -f '{{.State.Status}}' "$cid" 2>/dev/null)"
    health="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}-{{end}}' "$cid" 2>/dev/null)"
    ports="$(docker inspect -f '{{range $p,$v := .NetworkSettings.Ports}}{{$p}} {{end}}' "$cid" 2>/dev/null | tr -s ' ' | cut -c1-18)"
    started="$(docker inspect -f '{{.State.StartedAt}}' "$cid" 2>/dev/null | cut -c1-19)"
    [[ "$st" == "exited" ]] && st="exited($(docker inspect -f '{{.State.ExitCode}}' "$cid" 2>/dev/null))"
  fi
  if (( JSON )); then
    python3.11 -c "import json;print(json.dumps({'service':'$svc','status':'$st','health':'$health','started':'$started'},ensure_ascii=False))"
  else
    printf '%-13s %-14s %-14s %-20s %s\n' "$svc" "$st" "$health" "$ports" "$started"
  fi
  case "$st" in healthy|exited\(0\)) ;; *) rc=1 ;; esac
done
exit $rc
