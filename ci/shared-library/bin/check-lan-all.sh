#!/usr/bin/env bash
# 全服务局域网检测（M1）——并行调用 check-lan.sh 探测全部服务，输出 Markdown 汇总表。
# 用法：check-lan-all.sh [服务列表...]   默认探测 7 个核心服务。
# 退出码：任一服务失败即非 0；lan-report.md 写到当前目录（Jenkins archiveArtifacts 存档）。
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/check-lan.sh"

ALL=(dns ldap caddy homepage ldapadmin router jenkins)
SERVICES=("$@")
[[ ${#SERVICES[@]} -eq 0 ]] && SERVICES=("${ALL[@]}")

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "=== 并行探测 ${#SERVICES[@]} 个服务（时间戳重叠即真并发）==="
pids=()
for svc in "${SERVICES[@]}"; do
  (
    start="$(date +%H:%M:%S)"
    if bash "$SCRIPT" "$svc" >"$TMP/$svc.log" 2>&1; then st=OK; else st=FAIL; fi
    end="$(date +%H:%M:%S)"
    printf '%s\t%s\t%s\t%s\n' "$svc" "$st" "$start" "$end" > "$TMP/$svc.status"
  ) &
  pids+=($!)
done
for p in "${pids[@]}"; do wait "$p" 2>/dev/null || true; done

echo ""
echo "| 服务 | 结果 | 开始 | 结束 |"
|---|---|---|---|
failed=0
for svc in "${SERVICES[@]}"; do
  if [[ -f "$TMP/$svc.status" ]]; then
    IFS=$'\t' read -r s st b e < "$TMP/$svc.status"
    echo "| $s | $st | $b | $e |"
    [[ "$st" == "FAIL" ]] && failed=$((failed+1))
  else
    echo "| $svc | FAIL | - | - |"; failed=$((failed+1))
  fi
  echo "--- $svc console ---"
  cat "$TMP/$svc.log" 2>/dev/null || echo "(无输出)"
done

# Markdown 存档（供 archiveArtifacts）
{
  echo "# 局域网检测报告"
  echo ""
  echo "生成时间：$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo ""
  echo "| 服务 | 结果 | 开始 | 结束 |"
  echo "|---|---|---|---|"
  for svc in "${SERVICES[@]}"; do
    [[ -f "$TMP/$svc.status" ]] && { IFS=$'\t' read -r s st b e < "$TMP/$svc.status"; echo "| $s | $st | $b | $e |"; }
  done
} > lan-report.md
echo ""
echo "✓ 已生成 lan-report.md；失败 $failed 项"
[[ $failed -eq 0 ]]
