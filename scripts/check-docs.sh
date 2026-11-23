#!/usr/bin/env bash
# check-docs.sh —— 文档登记册双向一致门禁（IEEE 828 轻量落地）
# docs/**/*.md（除登记册自身与运行产物）必须在登记册里；册子里的路径必须真实存在。
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
REG="docs/文档登记册.md"
rc=0
[[ -f "$REG" ]] || { echo "✗ 缺 $REG" >&2; exit 1; }

# 磁盘上的文档（排除运行产物/台账/验收单）
mapfile -t disk < <(find docs -name '*.md' -type f \
  ! -path 'docs/文档登记册.md' \
  ! -path 'docs/records/执行日志/*' \
  ! -name 'M0-变更台账.md' ! -name 'M0-人工验收单.md' | sort)

# 册子里的路径（第 3 列）
mapfile -t reg < <(grep -oE 'docs/[^ |]+\.md' "$REG" | sort -u)

for f in "${disk[@]}"; do
  grep -qxF "$f" <(printf '%s\n' "${reg[@]}") || { echo "✗ 未登记: $f" >&2; rc=1; }
done
for f in "${reg[@]}"; do
  [[ -f "$f" ]] || { echo "✗ 册子挂着但文件不存在: $f" >&2; rc=1; }
done
[[ $rc -eq 0 ]] && echo "✓ 文档门禁通过：${#disk[@]} 篇双向一致（${#reg[@]} 条登记）"
exit $rc
