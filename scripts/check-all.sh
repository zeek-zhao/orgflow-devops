#!/usr/bin/env bash
# 重检查：pre-push 与 `make check-all` 调它。在快检查之上加 python 自检、lint、全栈 bats。
#
# 分层原则（踩过的坑写在这里，别再改回去）：
#   快检查放 pre-commit —— 几秒内，不需要 docker；
#   重检查放 pre-push —— 需要 docker，几分钟。
# 把重的塞进 pre-commit 的结局是「每次都 --no-verify」，等于没有钩子。
#
# bats 允许显式跳过：SKIP_BATS=1 git push。但必须打印「CI 会跑」——
# 静默跳过会让人以为验过了。
set -uo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1

failed=0
step() {
    local name="$1"; shift
    local start=$SECONDS
    if "$@" >/tmp/check-all.log 2>&1; then
        printf '  ✓ %-18s %ss\n' "$name" "$((SECONDS - start))"
    else
        printf '  ✗ %-18s %ss\n' "$name" "$((SECONDS - start))"
        sed 's/^/      /' /tmp/check-all.log | tail -25
        failed=1
    fi
}

echo "① 快检查"
bash scripts/check-fast.sh || failed=1

echo "② 自检与 lint"
if command -v make >/dev/null 2>&1; then
    step "make test" make test
    step "make lint" make lint
else
    echo "  · 本机没有 make，跳过 make test / lint（CI 会跑）"
fi

echo "③ 全栈行为（DinD）"
if [[ "${SKIP_BATS:-0}" == 1 ]]; then
    echo "  · SKIP_BATS=1：已显式跳过 bats —— CI 上 Test 工作流仍会跑 58 条断言"
elif ! command -v docker >/dev/null 2>&1; then
    echo "  · 本机没有 docker，跳过 bats —— CI 上 Test 工作流会跑"
else
    step "make test-bats" make test-bats
fi

if (( failed )); then
    echo
    echo "✗ 重检查未通过，别推。" >&2
    exit 1
fi
echo "✓ 重检查通过"
