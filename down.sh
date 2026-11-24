#!/usr/bin/env bash
# down.sh —— M0-v2 逐服务停机（反序，默认保留数据卷；零停机纪律：不 prune/不删网络卷）
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"
ENVFILE="config/defaults.env"
KEEP=1
for a in "$@"; do
  case "$a" in
    --keep-volumes) KEEP=1 ;;
    --remove-volumes) KEEP=0 ;;
    -h|--help) echo "用法: down.sh [--keep-volumes|--remove-volumes]（默认保留数据卷）"; exit 0 ;;
    *) echo "未知参数: $a" >&2; exit 2 ;;
  esac
done
mapfile -t ORDER < <(python3.11 -c "import csv; [print(r['service']) for r in csv.DictReader(open('services/manifest.tsv',encoding='utf-8-sig'),delimiter='\t')]")
echo "== 逐服务停机（反序: ${ORDER[*]}）=="
for ((i=${#ORDER[@]}-1; i>=0; i--)); do
  svc="${ORDER[$i]}"
  docker compose --env-file "$ENVFILE" -p "orgflow-$svc" -f "services/$svc/compose.yml" down >/dev/null 2>&1
  echo "  [down] $svc"
done
if (( ! KEEP )); then
  echo "✗ --remove-volumes 需人工确认后再单独执行 docker volume rm（本脚本不自动删卷，遵守 C-11）" >&2
  exit 2
fi
echo "✓ 已停全栈（数据卷与网络保留；需删除请人工执行）"
