#!/usr/bin/env bash
# verify-all.sh —— M3.0.4 T3：手动一键巡检（补自动化缺口，不设定时器）
#
# 按 ci/selfcheck/checks.tsv 顺序串行触发全部子 Job（默认排除 heavy 项 feat-review-flow，
# 即报告口径 21 项），逐项打印 SUCCESS/FAIL，末尾汇总。仅手动执行，不注册任何 cron/守护。
# 依赖 jenkins-trigger.sh 触发单个 Job 并等待结果；JENKINS_PASS 由调用方提供。
#
# 用法: JENKINS_PASS=... bash scripts/verify-all.sh
#   可选 HEAVY=1 时连 heavy 项（feat-review-flow）一起跑，共 22 项。
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"
TSV="ci/selfcheck/checks.tsv"
TRIGGER="scripts/jenkins-trigger.sh"
HEAVY="${HEAVY:-0}"

[ -f "$TSV" ] || { echo "✗ 缺 $TSV" >&2; exit 2; }
[ -f "$TRIGGER" ] || { echo "✗ 缺 $TRIGGER" >&2; exit 2; }
if [ -z "${JENKINS_PASS:-}" ]; then
  echo "✗ 需 JENKINS_PASS（jenkins-trigger.sh 认证）：JENKINS_PASS=... bash scripts/verify-all.sh" >&2
  exit 2
fi

pass=0; fail=0; skip=0; total=0
printf '%-24s %s\n' "JOB" "RESULT"
printf '%-24s %s\n' "------------------------" "------"
while IFS=$'\t' read -r id kind target title what expect timeout; do
  [ "$id" = "id" ] && continue           # 表头
  [ -z "$id" ] && continue               # 空行
  case "$kind" in job) ;; *) continue;; esac
  # heavy 项默认跳过（报告口径 21 = 22 数据行 - 1 heavy）
  if [ "$HEAVY" != "1" ] && [ "$id" = "feat-review-flow" ]; then
    printf '%-24s %s\n' "$target" "SKIP(heavy)"; skip=$((skip+1)); continue
  fi
  total=$((total+1))
  out="$(bash "$TRIGGER" "$target" 2>&1)"
  trc=$?
  # 从 console 输出里取 Jenkins 构建结果（"result: False SUCCESS" / "False FAILURE"）
  result="$(printf '%s\n' "$out" | grep -E '^result:' | tail -1 | awk '{print $3}')"
  [ -n "$result" ] || result="UNKNOWN(trigger_rc=$trc)"
  if [ "$result" = "SUCCESS" ]; then
    printf '%-24s %s\n' "$target" "SUCCESS"; pass=$((pass+1))
  else
    printf '%-24s %s\n' "$target" "FAIL($result)"; fail=$((fail+1))
    printf '%s\n' "$out" | tail -8
  fi
done < "$TSV"

echo "============================================================"
echo "verify-all 汇总: TOTAL=$total PASS=$pass FAIL=$fail SKIP(heavy)=$skip"
if [ "$fail" -eq 0 ] && [ "$total" -gt 0 ]; then
  echo "✓ 手动巡检通过（$pass/$total SUCCESS，无定时任务）"
  exit 0
else
  echo "✗ 手动巡检有失败（FAIL=$fail）"
  exit 1
fi
