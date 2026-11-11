#!/usr/bin/env bash
# 快检查：不需要 docker、不需要网络，几秒内跑完。pre-commit 与 `make check` 都调它。
#
# 为什么是独立脚本而不是写在钩子里：钩子里写逻辑就会和 CI 漂移 ——
# 门禁只有一份定义，钩子、make、CI 都调同一处，改规则时不会漏改。
# 也因为这台开发机上没有 `make`（Git Bash 环境），钩子不能依赖 make。
set -uo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1

# Windows 上通常只有 python，Linux 上是 python3；别把「解释器名不对」当成门禁失败
PY=""
for cand in python3 python; do
    if command -v "$cand" >/dev/null 2>&1; then PY="$cand"; break; fi
done
[ -n "$PY" ] || { echo "✗ 找不到 python 解释器" >&2; exit 1; }

failed=0
run() {
    local name="$1"; shift
    local start=$SECONDS
    if "$@" >/tmp/check-fast.log 2>&1; then
        printf '  ✓ %-16s %ss\n' "$name" "$((SECONDS - start))"
    else
        printf '  ✗ %-16s %ss\n' "$name" "$((SECONDS - start))"
        sed 's/^/      /' /tmp/check-fast.log | tail -20
        failed=1
    fi
}

echo "快检查（无 docker / 无网络）："
run "文档配置" "$PY" scripts/check_docs_meta.py
run "文档索引" "$PY" scripts/test_docs.py
run "死链" "$PY" scripts/check_export_links.py .
run "脱敏" bash scripts/check-public-redaction.sh .
run "标签清单" "$PY" scripts/test_labels.py

if (( failed )); then
    echo
    echo "✗ 快检查未通过。这些检查在 CI 上也跑，推上去一样会红。" >&2
    exit 1
fi
echo "✓ 快检查通过"
