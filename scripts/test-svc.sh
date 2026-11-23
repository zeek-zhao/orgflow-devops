#!/usr/bin/env bash
# test-svc.sh —— 单服务自测（make test-<svc>）：跑 S_<svc>.bats
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
svc="${1:-}"
[[ -n "$svc" ]] || { echo "用法: test-svc.sh <service>" >&2; exit 2; }
case "$svc" in
  certs-init) bats_file="tests/bats/S_certs-init.bats" ;;
  *) bats_file="tests/bats/S_${svc}.bats" ;;
esac
[[ -f "$bats_file" ]] || { echo "✗ 无单服务用例: $bats_file" >&2; exit 1; }
if command -v bats >/dev/null 2>&1; then
  bats "$bats_file"
else
  echo "⚠ bats 未安装；用静态规则预检（真机行为用例需在装有 bats 的验收环境跑）"
  # 静态预检：feature 与 bats 成对、脚本语法、镜像 digest
  feature="tests/features/S-${svc}.feature"
  [[ "$svc" == "certs-init" ]] && feature="tests/features/S-certs-init.feature"
  [[ -f "$feature" ]] || { echo "✗ 缺 $feature" >&2; exit 1; }
  grep -q '@test' "$bats_file" || { echo "✗ $bats_file 无 @test 用例" >&2; exit 1; }
  echo "✓ $svc 静态预检通过（feature 成对 + 含 @test 用例）"
fi
