#!/usr/bin/env bash
# check-selfcheck.sh —— 自检清单门禁（M2.4 Phase3，防止新增服务/Job 不进清单）
#
# 断言：
#   1. checks.tsv 表头固定 7 列（id/kind/target/title/what/expect/timeout），每行 7 列；
#   2. id 唯一；
#   3. kind=job 的 target 都能在 config/jenkins/jobs/*.groovy 生成（含 verify-${svc} 展开）；
#   4. 反向：所有 verify-* Job（除已在清单的）必须出现在 checks.tsv，否则 fail。
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
TSV="ci/selfcheck/checks.tsv"
rc=0

[[ -f "$TSV" ]] || { echo "✗ 缺 $TSV" >&2; exit 1; }

# ---- 1. 表头/列数 ----
header="$(head -1 "$TSV")"
want_hdr=$'id\tkind\ttarget\ttitle\twhat\texpect\ttimeout'
[[ "$header" == "$want_hdr" ]] || { echo "✗ 表头不符: $header" >&2; rc=1; }
n=0
while IFS=$'\t' read -r id kind target title what expect timeout extra; do
  [[ "$id" == "id" ]] && continue  # 表头
  [[ -n "$extra" ]] && { echo "✗ id=$id 列数>7" >&2; rc=1; }
  for f in "$id" "$kind" "$target" "$title" "$what" "$expect" "$timeout"; do
    if [[ -z "$f" ]]; then echo "✗ id=$id 有空列" >&2; rc=1; break; fi
  done
  n=$((n+1))
done < "$TSV"

# ---- 2. id 唯一 ----
dup="$(awk -F'\t' 'NR>1{print $1}' "$TSV" | sort | uniq -d)"
[[ -z "$dup" ]] || { echo "✗ id 重复: $dup" >&2; rc=1; }

# ---- 3. target 必须能被 Job DSL 生成 ----
# 收集所有 pipelineJob("...") 字面名 + verify-service.groovy 的 services 数组展开
jobs_file="$(mktemp)"
{
  grep -rhoE 'pipelineJob\(["'"'"'][^"'"'"']+["'"'"']\)' config/jenkins/jobs/*.groovy \
    | sed -E 's/pipelineJob\(["'"'"']([^"'"'"']+)["'"'"']\)/\1/'
  # 展开 verify-service.groovy 的 services 数组 → verify-<svc>
  svc_line="$(grep -E '^def services = \[' config/jenkins/jobs/verify-service.groovy || true)"
  if [[ -n "$svc_line" ]]; then
    for svc in $(echo "$svc_line" | grep -oE "'[a-z][a-z-]*'" | tr -d "'"); do
      echo "verify-${svc}"
    done
  fi
} | sort -u > "$jobs_file"

while IFS=$'\t' read -r id kind target title what expect timeout; do
  [[ "$id" == "id" ]] && continue
  [[ "$kind" == "job" ]] || continue
  grep -qxF "$target" "$jobs_file" || { echo "✗ target 无对应 Job: $target (id=$id)" >&2; rc=1; }
done < "$TSV"

# ---- 4. 反向：每个 verify-* Job 必须在清单 ----
# P2-1：按第 3 列整字段相等匹配（原 grep -qF 子串匹配会让 verify-cgit 被 verify-cgit-smart-http 顶替）。
while read -r job; do
  [[ "$job" == verify-* ]] || continue
  [[ "$job" == *'${'* ]] && continue  # 跳过未展开的模板字面 verify-${svc}
  awk -F'\t' -v t="$job" 'NR>1 && $3==t{found=1} END{exit found?0:1}' "$TSV" \
    || { echo "✗ Job $job 未登记进 checks.tsv（第3列整字段匹配）" >&2; rc=1; }
done < "$jobs_file"

rm -f "$jobs_file"

# ---- 5. m2.5.3 P2-2：报告/证据的 result 字段非空门禁 ----
# 5a. quota-guard.sh 必须写总体 result 字段（PASS/FAIL/WARN），否则机器消费者读到 null。
if ! grep -q 'result=' scripts/quota-guard.sh || ! grep -q 'result\\"' scripts/quota-guard.sh; then
  echo "✗ scripts/quota-guard.sh 未写 result 字段（m2.5.3 P2-2）" >&2; rc=1
fi
# 5b. selfcheck 报告生成脚本必须把 result/mechanism 写进 JSON（页面总判同口径 + 机制可见）。
if ! grep -q '"mechanism"' ci/jenkins/pipelines/selfcheck.Jenkinsfile; then
  echo "✗ selfcheck.Jenkinsfile 未写 mechanism 字段（m2.5.3 P0-2）" >&2; rc=1
fi
# 5c. guard-quota-alive 行必须登记（防假绿机制无自检项）。
awk -F'\t' 'NR>1 && ($1=="guard-quota-alive"){f=1} END{exit f?0:1}' "$TSV" \
  || { echo "✗ checks.tsv 缺 guard-quota-alive 行（m2.5.3 P0-2）" >&2; rc=1; }
# 5d. m2.5.4 P2-1：报告 buildJson 必须同时输出 result 与 overall（同值），
#     机器消费方按 result 读；缺一即 fail（运行时"两者相等"在验收用 jq 实测）。
if ! grep -q '"result":"' ci/jenkins/pipelines/selfcheck.Jenkinsfile \
   || ! grep -q '"overall":"' ci/jenkins/pipelines/selfcheck.Jenkinsfile; then
  echo "✗ selfcheck.Jenkinsfile buildJson 未同时输出 result/overall 字段（m2.5.4 P2-1）" >&2; rc=1
fi
# 5e. m2.5.4 P0-2：verify-quota-refresh 必须含 instances 判据，否则双实例不可观测。
if ! grep -q 'instances' ci/jenkins/pipelines/verify-quota-refresh.Jenkinsfile \
   || ! grep -q 'pidfile_pid' ci/jenkins/pipelines/verify-quota-refresh.Jenkinsfile; then
  echo "✗ verify-quota-refresh.Jenkinsfile 缺 instances/pidfile_pid 判据（m2.5.4 P0-2）" >&2; rc=1
fi
# 5f. m3.0.1 T2：verify-backup 四项断言关键字齐全（sh exit 非零即 FAILURE，无需脚本内写 currentBuild），
#     且 checks.tsv 必须登记 data-backup 行（自检 21 项）。
if ! grep -q 'total_volumes' ci/jenkins/pipelines/verify-backup.Jenkinsfile \
   || ! grep -q 'exit_code' ci/jenkins/pipelines/verify-backup.Jenkinsfile \
   || ! grep -q 'sha256sum -c' ci/jenkins/pipelines/verify-backup.Jenkinsfile; then
  echo "✗ verify-backup.Jenkinsfile 缺四项断言关键字（m3.0.1 T2）" >&2; rc=1
fi
awk -F'\t' 'NR>1 && ($1=="data-backup"){f=1} END{exit f?0:1}' "$TSV" \
  || { echo "✗ checks.tsv 缺 data-backup 行（m3.0.1 T2）" >&2; rc=1; }
if ! grep -q 'drill.result' ci/jenkins/pipelines/verify-restore-drill.Jenkinsfile \
   || ! grep -q 'changes 对齐 P=' ci/jenkins/pipelines/verify-restore-drill.Jenkinsfile \
   || ! grep -q 'healthy 数=3' ci/jenkins/pipelines/verify-restore-drill.Jenkinsfile; then
  echo "✗ verify-restore-drill.Jenkinsfile 缺 drill.result/changes 对齐/healthy=3 断言（m3.0.2 T5）" >&2; rc=1
fi
awk -F'\t' 'NR>1 && ($1=="data-drill"){f=1} END{exit f?0:1}' "$TSV" \
  || { echo "✗ checks.tsv 缺 data-drill 行（m3.0.1 T3）" >&2; rc=1; }
# 5g. m3.0.1 T4：报告与代码同源字段门禁；m3.0.2 T6：真校验 deployTag/tagCommit + consistent 口径。
if ! grep -q 'deployedHead' ci/jenkins/pipelines/selfcheck.Jenkinsfile \
   || ! grep -q 'consistent' ci/jenkins/pipelines/selfcheck.Jenkinsfile \
   || ! grep -q 'report-consistency' ci/jenkins/pipelines/verify-status-page.Jenkinsfile; then
  echo "✗ 缺报告同源字段（deployedHead/consistent/report-consistency，m3.0.1 T4）" >&2; rc=1
fi
if ! grep -q 'deployTag' ci/jenkins/pipelines/selfcheck.Jenkinsfile \
   || ! grep -q 'tagCommit' ci/jenkins/pipelines/selfcheck.Jenkinsfile \
   || ! grep -q 'describe --tags --exact-match HEAD' ci/jenkins/pipelines/selfcheck.Jenkinsfile \
   || ! grep -q 'tagCommit != ' ci/jenkins/pipelines/selfcheck.Jenkinsfile; then
  echo "✗ 缺报告同源真校验字段（deployTag/tagCommit/describe --tags --exact-match，m3.0.2 T6）" >&2; rc=1
fi
if ! grep -q 'deployTag' ci/jenkins/pipelines/verify-status-page.Jenkinsfile \
   || ! grep -q 'tagCommit' ci/jenkins/pipelines/verify-status-page.Jenkinsfile; then
  echo "✗ verify-status-page 缺 deployTag/tagCommit 断言（m3.0.2 T6）" >&2; rc=1
fi

if [[ $rc -eq 0 ]]; then
  echo "✓ 自检清单门禁：${n} 项（表头/列/id 唯一/target 存在/verify-* 全覆盖/result+overall+mechanism+alive+instances/backup 断言字段）"
fi
exit $rc
