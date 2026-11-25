#!/usr/bin/env bash
# test-static.sh —— 静态自检：python 语法、配置必填项、shell 语法
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
rc=0
fail(){ echo "✗ $*" >&2; rc=1; }

# 1. 所有 scripts/*.sh + ci 共享库脚本语法
for f in scripts/*.sh ci/shared-library/bin/*.sh; do
  [[ -f "$f" ]] || continue
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

# T9.6：JENKINS_URL 的 host 必须等于 PUBLIC_HOST（防止双处硬编码漂移）。
PH="$(grep -E '^PUBLIC_HOST=' config/defaults.env | head -1 | cut -d= -f2-)"
JU="$(grep -E '^JENKINS_URL=' config/defaults.env | head -1 | cut -d= -f2-)"
if [[ -n "$PH" && -n "$JU" ]] && ! echo "$JU" | grep -q "://${PH}/"; then
  fail "JENKINS_URL 的 host 与 PUBLIC_HOST 不一致：$JU vs $PH"
fi

# 4. YAML 解析（M1 T9.4）：挡住 compose environment map/list 混用这类致命错误。
#    jenkins.yaml 含 ${VAR} 字符串，safe_load 不报错（已验证）。
if python3 - <<'PY'
import glob, yaml, sys
files = [f for f in glob.glob('services/*/compose.yml') if '/_' not in f.split('/')[1]] + glob.glob('config/**/*.yaml', recursive=True)
bad = []
for f in files:
    try:
        with open(f, encoding='utf-8') as fh:
            yaml.safe_load(fh)
    except Exception as e:
        bad.append(f"{f}: {e}")
if bad:
    print("\n".join("✗ YAML 解析失败: " + b for b in bad)); sys.exit(1)
print(f"  ✓ YAML 解析（{len(files)} 个文件）")
PY
then :; else rc=1; fi

[[ $rc -eq 0 ]] && echo "✓ 静态自检通过（shell 语法 + 配置必填 + YAML 解析）"
exit $rc
