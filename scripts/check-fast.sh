#!/usr/bin/env bash
# check-fast.sh —— 快检查聚合器（无 docker / 无网络，几秒）
# 每个子检查是独立脚本：存在则跑，不存在则打印「检查项待补」。
# 这样空骨架阶段 make check 退出 0，随着 T2/T9 逐项落地自动纳入。
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
rc=0
run() {
  local label="$1" script="$2"; shift 2
  local extra=("$@")
  if [[ -f "$script" ]]; then
    printf '  ✓ %-12s ' "$label"
    if bash "$script" "${extra[@]}" >/tmp/check.out 2>&1; then echo "ok"; else echo "红"; cat /tmp/check.out; rc=1; fi
  else
    printf '  - %-12s 检查项待补（%s）\n' "$label" "${script#./}"
  fi
}
echo "快检查（无 docker / 无网络）："
run 记录留存 scripts/check_record_exists.sh
run 镜像摘要 scripts/check-images.sh --mode=digest
run 基底统一 scripts/check-images.sh --mode=base
run 上游摘要 scripts/check-images.sh --mode=upstream
# T11：--mode=lock 严格模式（零 PENDING）由 CI 与 up.sh 本地镜像前置校验使用；
# 日常快检查用 digest（格式合法，PENDING 仅提示），避免沙箱环境限制使日常门禁长期红。
run 摘要一致 scripts/check-images.sh --mode=digest
run 配置解析 scripts/test-static.sh
run 文档登记 scripts/check-docs.sh
run 域名配置 scripts/check-domain.sh
run 测试覆盖 tests/check-v2.sh
if [[ $rc -eq 0 ]]; then echo "✓ 快检查通过"; else echo "✗ 快检查未通过" >&2; fi
exit $rc
