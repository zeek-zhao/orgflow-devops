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
if [[ $rc -eq 0 ]]; then
  echo "✓ 自检清单门禁：${n} 项（表头/列/id 唯一/target 存在/verify-* 全覆盖）"
fi
exit $rc
