#!/usr/bin/env bash
# check-jenkins-warnings.sh —— 警告台账核对（REQ-M0-B3 / #92）
#
# 用法：bash scripts/check-jenkins-warnings.sh [快照] [台账]
#   默认快照 docs/services/jenkins.warnings（由 collect-jenkins-warnings.sh --save 生成）
#   默认台账 docs/services/jenkins.md 的「警告台账」表格
#
# 断言：① 快照里每个警告编号都必须在台账登记（否则报「未登记」）
#       ② 台账里每个编号都必须在快照里（否则报「已消解/陈旧」）
#       ③ 台账每条的处置列是「已修」或「不修」，理由与复核日期非空
# 任一不满足退出码 1。纯文件比对，不连 213，可在 CI 复跑。

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SNAP="${1:-$ROOT/docs/services/jenkins.warnings}"
LEDGER="${2:-$ROOT/docs/services/jenkins.md}"

if [ ! -r "$SNAP" ];   then echo "快照不可读: $SNAP" >&2; exit 2; fi
if [ ! -r "$LEDGER" ]; then echo "台账不可读: $LEDGER" >&2; exit 2; fi

snap_ids="$(awk 'NF && $1 !~ /^#/ {print $1}' "$SNAP" | sort -u)"
ledger_lines="$(grep -E '^\| W-[0-9]+ \|' "$LEDGER" || true)"
ledger_ids="$(printf '%s\n' "$ledger_lines" | grep -oE '^\| W-[0-9]+' | tr -d '| ' | sort -u || true)"

snap_n="$(printf '%s\n' "$snap_ids"   | grep -c . || true)"
ledger_n="$(printf '%s\n' "$ledger_ids" | grep -c . || true)"
echo "实际警告数(快照): $snap_n"
echo "台账条目数:       $ledger_n"

rc=0
unreg="$(comm -23 <(printf '%s\n' "$snap_ids") <(printf '%s\n' "$ledger_ids") | grep -v '^$' || true)"
stale="$(comm -13 <(printf '%s\n' "$snap_ids") <(printf '%s\n' "$ledger_ids") | grep -v '^$' || true)"
if [ -n "$unreg" ]; then
  echo "✗ 未登记（实际警告但台账没有）: $(echo $unreg)"
  rc=1
fi
if [ -n "$stale" ]; then
  echo "✗ 台账有但快照没有（已消解/陈旧）: $(echo $stale)"
  rc=1
fi

bad="$(printf '%s\n' "$ledger_lines" | awk -F'|' '
  /^\| W-[0-9]+/ {
    id=$2; disp=$4; why=$5; when=$6
    gsub(/^ +| +$/, "", id); gsub(/^ +| +$/, "", disp)
    gsub(/^ +| +$/, "", why); gsub(/^ +| +$/, "", when)
    if (disp != "已修" && disp != "不修") print "  " id ": 处置列必须是 已修/不修 (当前=" disp ")"
    if (why == "")  print "  " id ": 理由为空"
    if (when == "") print "  " id ": 复核日期为空"
  }' || true)"
if [ -n "$bad" ]; then
  echo "✗ 台账字段不完整:"
  echo "$bad"
  rc=1
fi

if [ "$rc" -eq 0 ]; then
  echo "✓ 台账条目数与实际警告数一致，且每条都有处置/理由/复核日期"
fi
exit "$rc"
