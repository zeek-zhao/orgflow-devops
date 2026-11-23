#!/usr/bin/env bash
# record.sh —— 操作记录落盘（NFR-09 可审计 / REQ-MIN-13）
# 一次调用，在两处各留痕：执行日志（结构化）+ 变更台账（一 PR 一行，按 issue 去重）。
# 命令原文与输出落 artifacts/，不截断。
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG_DIR="$ROOT/docs/records/执行日志"
ART_DIR="$LOG_DIR/artifacts"
LEDGER="$ROOT/docs/records/M0-变更台账.md"

issue="" summary="" cmd="" result="" pr="" actor="AI" out_file=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --issue)   issue="${2:-}";   shift 2 ;;
    --summary) summary="${2:-}"; shift 2 ;;
    --cmd)     cmd="${2:-}";     shift 2 ;;
    --result)  result="${2:-}";  shift 2 ;;
    --pr)      pr="${2:-}";      shift 2 ;;
    --actor)   actor="${2:-}";   shift 2 ;;
    --out)     out_file="${2:-}";shift 2 ;;
    -h|--help) sed -n '2,6p' "$0"; exit 0 ;;
    *) echo "未知参数: $1" >&2; exit 2 ;;
  esac
done
[[ -n "$issue" ]]   || { echo "缺 --issue" >&2; exit 2; }
[[ -n "$summary" ]] || { echo "缺 --summary" >&2; exit 2; }

date_s="$(date +%F)"; ts="$(date '+%Y-%m-%d %H:%M:%S %z')"
mkdir -p "$LOG_DIR" "$ART_DIR"
log_file="$LOG_DIR/${date_s}.md"

artifact_rel=""
if [[ -n "$cmd" || -n "$out_file" ]]; then
  seq=$(( $(find "$ART_DIR" -maxdepth 1 -name "${date_s}-${issue}-*" 2>/dev/null | wc -l) + 1 ))
  artifact_rel="artifacts/${date_s}-${issue}-${seq}.log"
  { echo "# command"; echo "$cmd"; echo "# output"; [[ -n "$out_file" ]] && cat "$out_file"; } \
    > "$ART_DIR/${date_s}-${issue}-${seq}.log"
fi

[[ -f "$log_file" ]] || cat > "$log_file" <<EOF
# 执行日志 $date_s

> 由 \`scripts/record.sh\` 生成。每条：时间 / 执行者 / 关联 Issue / 完整命令 / 输出摘要 / 结论。原样输出见 \`artifacts/\`。

EOF
{
  echo "## $issue — $summary"; echo
  echo "- **时间**：$ts"; echo "- **执行者**：$actor"; echo "- **关联 Issue**：$issue"
  [[ -n "$pr" ]] && echo "- **PR**：#$pr"
  echo "- **完整命令**：\`${cmd:-（无，人工记录）}\`"
  [[ -n "$artifact_rel" ]] && echo "- **原始输出**：\`$artifact_rel\`"
  echo "- **结论**：${result:-（见原始输出）}"; echo
} >> "$log_file"

[[ -f "$LEDGER" ]] || cat > "$LEDGER" <<'EOF'
# M0 变更台账

> 一 PR 一行，由 `scripts/record.sh --pr` 维护。列：PR / Issue / 摘要 / 验证结果 / 日期。

| PR | Issue | 摘要 | 验证结果 | 日期 |
|----|-------|------|----------|------|
EOF
pr_cell="${pr:+#$pr}"
row="| ${pr_cell:-—} | $issue | $summary | ${result:-见执行日志} | $date_s |"
tmp="$(mktemp)"
awk -v iss="$issue" -v row="$row" '
  BEGIN{done=0} /^\|/{n=split($0,f,"|"); if(n>=5){c=f[3];gsub(/^[[:space:]]+|[[:space:]]+$/,"",c); if(c==iss&&!done){print row;done=1;next}}} {print} END{if(!done)print row}
' "$LEDGER" > "$tmp" && mv "$tmp" "$LEDGER"
echo "✓ 已记录 $issue → $log_file + $LEDGER"
