#!/usr/bin/env bash
# =============================================================================
# check_record_exists.sh —— 记录留存门禁（REQ-MIN-13 / AC-15 / NFR-09）
#
#   PR 门禁调用：某个任务声称完成，必须有对应的 record 才能合。
#   「没留记录 = 无法审计 = 无法复现」，所以缺记录直接红。
#
#   检查两处：
#     ① docs/records/执行日志/*.md 里出现该 issue 的标题
#     ② docs/records/M0-变更台账.md 的 Issue 列含该 issue
#
# 用法：
#   bash scripts/check_record_exists.sh T0
#   bash scripts/check_record_exists.sh T0 T1 T2     # 多个
#   bash scripts/check_record_exists.sh              # 无参：只校验文件结构存在
#
#   退出 0 = 全部有记录；非 0 = 有缺漏（打印缺哪些）。
# =============================================================================
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG_DIR="$ROOT/docs/records/执行日志"
LEDGER="$ROOT/docs/records/M0-变更台账.md"

rc=0

if [[ ! -d "$LOG_DIR" ]]; then
  echo "✗ 缺目录 docs/records/执行日志/" >&2
  rc=1
fi
if [[ ! -f "$LEDGER" ]]; then
  echo "✗ 缺文件 docs/records/M0-变更台账.md" >&2
  rc=1
fi

# 无参：只做结构校验
if [[ $# -eq 0 ]]; then
  if [[ "$rc" -eq 0 ]]; then
    echo "✓ 记录载体存在（执行日志/ + M0-变更台账.md）"
  fi
  exit "$rc"
fi

for issue in "$@"; do
  in_log=0
  in_ledger=0

  if compgen -G "$LOG_DIR/*.md" > /dev/null 2>&1; then
    if grep -rlE "^## ${issue}([[:space:]]|—|$)" "$LOG_DIR"/*.md >/dev/null 2>&1; then
      in_log=1
    fi
  fi

  if [[ -f "$LEDGER" ]] && awk -F'|' -v iss="$issue" '
    { c=$3; gsub(/^[[:space:]]+|[[:space:]]+$/, "", c); if (c==iss) found=1 }
    END { exit(found?0:1) }
  ' "$LEDGER"; then
    in_ledger=1
  fi

  if [[ "$in_log" -eq 1 && "$in_ledger" -eq 1 ]]; then
    echo "✓ $issue：执行日志 + 变更台账均有记录"
  else
    echo "✗ $issue：记录不全（执行日志=$in_log 变更台账=$in_ledger）" >&2
    rc=1
  fi
done

exit "$rc"
