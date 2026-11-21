#!/usr/bin/env bash
# 改坏三处 → 门禁必须红；恢复 → 必须绿。只贴绿的一半不算验证。
#
# 为什么用「写回原内容」而不是 git checkout：本次重构把这些文件整体重写了，
# 分支上它们还是**未提交**状态，`git checkout --` 会把改动一起丢掉（踩过）。
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1
fail=0
BK=/tmp/cf-backup; rm -rf "$BK"; mkdir -p "$BK"

backup() { mkdir -p "$BK/$(dirname "$1")"; cp -p "$1" "$BK/$1"; }
restore() { cp -p "$BK/$1" "$1"; }

say() { printf '%s\n' "$*"; }

CFG=config/services.yml
LDAP_COMPOSE=services/ldap/compose.yml
LIB=scripts/lib/config.py

backup "$CFG"; backup "$LDAP_COMPOSE"; backup "$LIB"

say "== 反证 1：$CFG 里 ldap 的 ip 改成与 jenkins 相同（20）=="
python3 - "$CFG" <<'PY'
import re, sys, pathlib
p = pathlib.Path(sys.argv[1]); s = p.read_text(encoding="utf-8")
s2, n = re.subn(r"(\n  ldap:\n(?:.*\n)*?    ip: )\d+", r"\g<1>20", s, count=1)
assert n == 1, "锚点没命中"
p.write_text(s2, encoding="utf-8")
PY
if python3 scripts/test_config.py >/tmp/cf1.log 2>&1; then say "✗ 反证1 没红"; fail=1; else say "✓ 反证1 红：$(grep -m1 -o '撞 IP[^"]*' /tmp/cf1.log)"; fi
restore "$CFG"

say "== 反证 2：$LDAP_COMPOSE 写死 172.31.0.22 =="
python3 - "$LDAP_COMPOSE" <<'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1]); s = p.read_text(encoding="utf-8")
assert "${IP_LDAP}" in s, "锚点没命中"
p.write_text(s.replace("${IP_LDAP}", "172.31.0.22", 1), encoding="utf-8")
PY
if python3 scripts/test_config.py >/tmp/cf2.log 2>&1; then say "✗ 反证2 没红"; fail=1; else say "✓ 反证2 红：$(grep -m1 -o 'services/ldap/compose.yml:[0-9]*' /tmp/cf2.log)"; fi
restore "$LDAP_COMPOSE"

say "== 反证 3：$LIB 不再产出 IP_<SERVICE> =="
python3 - "$LIB" <<'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1]); s = p.read_text(encoding="utf-8")
old = '        pairs[f"IP_{name.upper().replace(\'-\', \'_\')}"] = fixed_ip(cfg, spec)\n    for name, spec in (services.get("external") or {}).items():'
new = '        pass\n    for name, spec in (services.get("external") or {}).items():'
assert old in s, "锚点没命中"
p.write_text(s.replace(old, new, 1), encoding="utf-8")
PY
if python3 scripts/test_config.py >/tmp/cf3.log 2>&1; then say "✗ 反证3 没红"; fail=1; else say "✓ 反证3 红：$(grep -m1 -o "渲染不产出：[^']*'[^']*'" /tmp/cf3.log | cut -c1-70)"; fi
restore "$LIB"

say "== 恢复后必须绿 =="
if python3 scripts/test_config.py >/tmp/cf4.log 2>&1; then say "✓ $(grep -o 'Ran [0-9]* tests' /tmp/cf4.log) 全绿（恢复后）"; else say "✗ 恢复后仍红"; tail -20 /tmp/cf4.log; fail=1; fi
if [ "$(cat "$BK/$CFG")" = "$(cat "$CFG")" ] && [ "$(cat "$BK/$LDAP_COMPOSE")" = "$(cat "$LDAP_COMPOSE")" ] && [ "$(cat "$BK/$LIB")" = "$(cat "$LIB")" ]; then
  say "✓ 三个被改坏的文件已按原内容还原"
else
  say "✗ 还原不完整"; fail=1
fi
exit $fail
