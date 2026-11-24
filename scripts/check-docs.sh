#!/usr/bin/env bash
# check-docs.sh —— 文档登记册双向一致门禁（IEEE 828 轻量落地）
# 登记册已并入 docs/README.md 附录（M0-v2 R4b）；docs/**/*.md（除 README 自身与
# 运行产物）必须在登记表里；表里的路径必须真实存在。
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
REG="docs/README.md"
rc=0
[[ -f "$REG" ]] || { echo "✗ 缺 $REG" >&2; exit 1; }

# 磁盘上的文档（排除 README 自身/运行产物/台账/验收单）
mapfile -t disk < <(find docs -name '*.md' -type f \
  ! -path 'docs/README.md' \
  ! -path 'docs/records/执行日志/*' \
  ! -name 'M0-变更台账.md' ! -name 'M0-人工验收单.md' ! -name 'M0-截图清单.md' \
  ! -name 'M0-v2-复检修复对照表.md' ! -name 'M0-v3-当前状态表.md' | sort)

# 登记表中的路径：只取「| DOC-... 」行的第 3 列（反引号里的角色阅读链接不算）
mapfile -t reg < <(grep -E '^\| DOC-[A-Z]-[0-9]+' "$REG" | awk -F'|' '{gsub(/^[ \t]+|[ \t]+$/, "", $4); print $4}' | grep '^docs/' | sort -u)

for f in "${disk[@]}"; do
  grep -qxF "$f" <(printf '%s\n' "${reg[@]}") || { echo "✗ 未登记: $f" >&2; rc=1; }
done
for f in "${reg[@]}"; do
  [[ -f "$f" ]] || { echo "✗ 册子挂着但文件不存在: $f" >&2; rc=1; }
done
[[ $rc -eq 0 ]] && echo "✓ 文档门禁通过：${#disk[@]} 篇双向一致（${#reg[@]} 条登记）"
exit $rc
