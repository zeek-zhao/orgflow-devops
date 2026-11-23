#!/usr/bin/env bash
# =============================================================================
# record.sh —— 操作记录落盘（方案书 §5「记录留存」/ NFR-09 可审计 / REQ-MIN-13）
#
#   一条命令，在两处各留一行：
#     ① docs/records/执行日志/<YYYY-MM-DD>.md   追加一条结构化记录
#     ② docs/records/M0-变更台账.md             追加/更新一行台账
#   原文输出落 artifacts/，不截断（超 2MB 的由 CI 转 artifact）。
#
#   为什么必须是脚本而不是「手写」：审计要求「任一交付结论都能追溯到
#   Issue + PR + record + 命令输出」。手写会漏字段、漏日期、格式漂移，
#   于是 check_record_exists.sh 无法机器校验，等于没有门禁。
#
# 用法：
#   bash scripts/record.sh --issue T0 --summary "建立治理基座" \
#        --cmd "bash scripts/check_record_exists.sh T0" \
#        --result "exit 0" --pr 169 --actor AI
#
#   --issue    必填，任务号（T0..T9）或任意短标记
#   --summary  必填，一句话摘要
#   --cmd      可选，本次执行的完整命令（会连同输出写进 artifacts）
#   --result   可选，结论（exit 码 / 关键输出摘要）
#   --pr       可选，PR 号
#   --actor    可选，默认 AI（取值 AI 或 人名）
#   --out      可选，命令的原始输出文件（提供则原样复制进 artifacts）
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG_DIR="$ROOT/docs/records/执行日志"
ART_DIR="$LOG_DIR/artifacts"
LEDGER="$ROOT/docs/records/M0-变更台账.md"

issue=""
summary=""
cmd=""
result=""
pr=""
actor="AI"
out_file=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --issue)   issue="${2:-}";   shift 2 ;;
    --summary) summary="${2:-}"; shift 2 ;;
    --cmd)     cmd="${2:-}";     shift 2 ;;
    --result)  result="${2:-}";  shift 2 ;;
    --pr)      pr="${2:-}";      shift 2 ;;
    --actor)   actor="${2:-}";   shift 2 ;;
    --out)     out_file="${2:-}";shift 2 ;;
    -h|--help) sed -n '2,26p' "$0"; exit 0 ;;
    *) echo "✗ 未知参数: $1（用 --help 看用法）" >&2; exit 2 ;;
  esac
done

[[ -n "$issue" ]]   || { echo "✗ 缺 --issue" >&2; exit 2; }
[[ -n "$summary" ]] || { echo "✗ 缺 --summary" >&2; exit 2; }

date_s="$(date +%F)"
ts="$(date '+%Y-%m-%d %H:%M:%S %z')"
mkdir -p "$LOG_DIR" "$ART_DIR"
log_file="$LOG_DIR/${date_s}.md"

# ---- artifacts：把命令原文与输出原样落盘（不截断）----
artifact_rel=""
if [[ -n "$cmd" || -n "$out_file" ]]; then
  seq="$(find "$ART_DIR" -maxdepth 1 -name "${date_s}-${issue}-*" 2>/dev/null | wc -l | tr -d ' ')"
  seq=$((seq + 1))
  artifact_rel="artifacts/${date_s}-${issue}-${seq}.log"
  {
    echo "# command"
    echo "$cmd"
    echo "# output"
    if [[ -n "$out_file" ]]; then
      cat "$out_file"
    fi
  } > "$ART_DIR/${date_s}-${issue}-${seq}.log"
fi

# ---- ① 执行日志：追加一条结构化记录 ----
if [[ ! -f "$log_file" ]]; then
  cat > "$log_file" <<EOF
# 执行日志 $date_s

> 由 \`scripts/record.sh\` 生成。每条记录：时间 / 执行者 / 关联 Issue / 完整命令 / 输出摘要 / 结论。
> 原样输出见 \`artifacts/\`。永久入库。

EOF
fi

{
  echo "## $issue — $summary"
  echo
  echo "- **时间**：$ts"
  echo "- **执行者**：$actor"
  echo "- **关联 Issue**：$issue"
  [[ -n "$pr" ]]     && echo "- **PR**：#$pr"
  echo "- **完整命令**：\`${cmd:-（无，人工记录）}\`"
  [[ -n "$artifact_rel" ]] && echo "- **原始输出**：\`$artifact_rel\`"
  echo "- **结论**：${result:-（见原始输出）}"
  echo
} >> "$log_file"

# ---- ② 变更台账：一条 PR 一行，按 issue 去重（重跑则更新该行）----
if [[ ! -f "$LEDGER" ]]; then
  cat > "$LEDGER" <<'EOF'
# M0 变更台账

> 一个 PR 一行。由 `scripts/record.sh --pr` 维护，手工增删会被下次 record 覆盖对应行。
> 列：PR / Issue / 摘要 / 验证结果 / 日期。永久入库，覆盖全部 M0 PR。

| PR | Issue | 摘要 | 验证结果 | 日期 |
|----|-------|------|----------|------|
EOF
fi

pr_cell="${pr:+#$pr}"
row="| ${pr_cell:-—} | $issue | $summary | ${result:-见执行日志} | $date_s |"
tmp="$(mktemp)"
awk -v iss="$issue" -v row="$row" '
  BEGIN { done=0 }
  # 匹配 Issue 列（第 3 个管道字段）等于 iss 的数据行：$2 是 Issue
  /^\|/ {
    n=split($0, f, "|")
    if (n>=5) {
      cell=f[3]
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", cell)
      if (cell==iss && !done) { print row; done=1; next }
    }
  }
  { print }
  END { if (!done) print row }
' "$LEDGER" > "$tmp"
mv "$tmp" "$LEDGER"

echo "✓ 已记录 $issue："
echo "  - $log_file"
echo "  - $LEDGER"
[[ -n "$artifact_rel" ]] && echo "  - $ART_DIR/$(basename "$artifact_rel")"
