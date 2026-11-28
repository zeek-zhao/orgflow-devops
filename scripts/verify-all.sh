#!/usr/bin/env bash
# verify-all.sh —— M3.0.4 T3：手动一键巡检（补自动化缺口，不设定时器）
#
# 按 ci/selfcheck/checks.tsv 顺序串行触发全部子 Job（默认排除 heavy 项 feat-review-flow，
# 即报告口径 21 项），逐项打印 SUCCESS/FAIL，末尾汇总。仅手动执行，不注册任何 cron/守护。
# 依赖 jenkins-trigger.sh 触发单个 Job 并等待结果；JENKINS_PASS 由调用方提供。
#
# m3.0.5 T4（D4）：从 checks.tsv 第 7 列读 timeout（分钟）传给 jenkins-trigger.sh 作等待上限；
#   超时（trigger 输出 "result: TIMEOUT" / exit 5）判 FAIL(timeout)，不得写 UNKNOWN。
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
  # m3.0.5 T4：按 checks.tsv 的 timeout（分钟，第7列）传等待上限；空/非法回落默认 6。
  tmin="${timeout:-6}"; case "$tmin" in ''|*[!0-9]*) tmin=6;; esac
  out="$(bash "$TRIGGER" "$target" "" "$tmin" 2>&1)"
  trc=$?
  # 超时优先判定：trigger 以 "result: TIMEOUT" + exit 5 表示等待超上限（m3.0.5 T4）。
  if printf '%s\n' "$out" | grep -qE '^result: TIMEOUT' || [ "$trc" -eq 5 ]; then
    printf '%-24s %s\n' "$target" "FAIL(timeout)"; fail=$((fail+1))
    printf '%s\n' "$out" | tail -8
    continue
  fi
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
