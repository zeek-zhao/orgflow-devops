#!/usr/bin/env bash
# check_record_exists.sh —— 记录留存门禁（REQ-MIN-13 / AC-15）
# 有 record 才允许合 PR；缺记录直接红。检查执行日志 + 变更台账两处。
# 用法: check_record_exists.sh T0 [T1 ...]；无参只校验文件结构。
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG_DIR="$ROOT/docs/records/执行日志"
LEDGER="$ROOT/docs/records/M0-变更台账.md"
rc=0
[[ -d "$LOG_DIR" ]] || { echo "✗ 缺 docs/records/执行日志/" >&2; rc=1; }
[[ -f "$LEDGER" ]] || { echo "✗ 缺 docs/records/M0-变更台账.md" >&2; rc=1; }
[[ $# -eq 0 ]] && { [[ $rc -eq 0 ]] && echo "✓ 记录载体存在"; exit $rc; }
for issue in "$@"; do
  in_log=0; in_ledger=0
  if compgen -G "$LOG_DIR/*.md" >/dev/null 2>&1; then
    grep -rlE "^## ${issue}([[:space:]]|—|$)" "$LOG_DIR"/*.md >/dev/null 2>&1 && in_log=1
  fi
  if [[ -f "$LEDGER" ]] && awk -F'|' -v iss="$issue" '{c=$3;gsub(/^[[:space:]]+|[[:space:]]+$/,"",c);if(c==iss)f=1}END{exit(f?0:1)}' "$LEDGER"; then in_ledger=1; fi
  if [[ $in_log -eq 1 && $in_ledger -eq 1 ]]; then
    echo "✓ $issue：执行日志 + 变更台账均有记录"
  else
    echo "✗ $issue：记录不全（日志=$in_log 台账=$in_ledger）" >&2; rc=1
  fi
done
exit $rc
