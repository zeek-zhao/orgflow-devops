#!/usr/bin/env bash
# supervisor-conf-dir.sh —— 解析 supervisor conf 目录（m2.5.4 P1-1 安装可移植性）
#
# 只输出一个"已存在的绝对目录路径"到 stdout；任何失败都 exit 2 且写 stderr。
# 探测顺序（严格）：
#   1) 环境变量 SUPERVISOR_CONF_DIR（显式覆盖，最高优先级）——目录必须存在，否则 exit 2；
#   2) supervisorctl 可用 → /etc/supervisor/conf.d（真机默认）；
#   3) 读 supervisord.conf 的 [include] files 行，展开 %(ENV_X)s，取第一个"非
#      /usr/local/share/supervisor 且真实存在"的目录（沙箱云 IDE 的 include 首路径）；
#   4) 以上都拿不到 → exit 2，绝不静默落到 /usr/local/share/supervisor。
#
# 为什么排除 /usr/local/share/supervisor：那是本沙箱云 IDE 的次要 include 目录，
# 真机上无此目录，写进去等于"写了就算装好"的假绿。
set -uo pipefail

die() { echo "✗ supervisor-conf-dir: $*" >&2; exit 2; }

# 1) 显式覆盖
if [ -n "${SUPERVISOR_CONF_DIR:-}" ]; then
  [ -d "$SUPERVISOR_CONF_DIR" ] || die "显式 SUPERVISOR_CONF_DIR 不存在: $SUPERVISOR_CONF_DIR"
  printf '%s\n' "$SUPERVISOR_CONF_DIR"
  exit 0
fi

# 2) supervisorctl 可用 → 真机默认目录
if command -v supervisorctl >/dev/null 2>&1; then
  if [ -d /etc/supervisor/conf.d ]; then
    printf '%s\n' /etc/supervisor/conf.d
    exit 0
  fi
fi

# 3) 读 supervisord.conf 的 include 行
conf=""
for c in "${IDE_EDITOR_SERVER_DIR:-}/supervisord-conf/supervisord.conf" \
         /etc/supervisor/supervisord.conf /etc/supervisord.conf; do
  [ -n "$c" ] && [ -f "$c" ] && { conf="$c"; break; }
done
[ -n "$conf" ] || die "找不到 supervisord.conf；请显式传 SUPERVISOR_CONF_DIR=<已存在目录>"

# 展开 %(ENV_X)s → 环境变量值；逐 token 取目录，跳过 /usr/local/share/supervisor。
python3 - "$conf" <<'PY' || die "无法从 $conf 的 include 行解析出可用目录；请显式传 SUPERVISOR_CONF_DIR=<已存在目录>"
import os, re, sys, glob
text = open(sys.argv[1], encoding='utf-8', errors='replace').read()
def expand(s):
    return re.sub(r'%\((?:ENV_)?([A-Za-z0-9_]+)\)s',
                  lambda m: os.environ.get(m.group(1), ''), s)
for line in text.splitlines():
    m = re.match(r'\s*files\s*=\s*(.+)', line)
    if not m:
        continue
    for tok in m.group(1).split():
        d = os.path.dirname(expand(tok))
        if not d or 'usr/local/share/supervisor' in d:
            continue
        hits = sorted(glob.glob(d))
        if hits and os.path.isdir(hits[0]):
            print(hits[0])
            sys.exit(0)
sys.exit(1)
PY
