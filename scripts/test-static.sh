#!/usr/bin/env bash
# test-static.sh —— 静态自检：python 语法、配置必填项、shell 语法
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
rc=0
fail(){ echo "✗ $*" >&2; rc=1; }

# 1. 所有 scripts/*.sh 语法
for f in scripts/*.sh; do
  bash -n "$f" 2>/dev/null || fail "shell 语法错误: $f"
done

# 2. 所有 python 文件语法（若存在）
if compgen -G 'services/*/*.py' >/dev/null || compgen -G 'scripts/*.py' >/dev/null; then
  if python3 - <<'PY'
import pathlib, py_compile
files = list(pathlib.Path('.').glob('services/**/*.py')) + list(pathlib.Path('.').glob('scripts/**/*.py'))
bad = []
for f in files:
    try: py_compile.compile(str(f), doraise=True)
    except Exception as e: bad.append((f, e))
if bad:
    for f, e in bad: print(f"✗ python 语法错误: {f}: {e}")
    raise SystemExit(1)
print("  ✓ python 语法")
PY
  then :; else rc=1; fi
fi

# 3. 配置必填项
for key in DOMAIN IP_CADDY IP_DNSMASQ; do
  grep -qE "^${key}=" config/defaults.env || fail "config/defaults.env 缺 $key"
done

[[ $rc -eq 0 ]] && echo "✓ 静态自检通过（shell 语法 + 配置必填）"
exit $rc
