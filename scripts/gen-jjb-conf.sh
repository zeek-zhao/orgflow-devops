#!/usr/bin/env bash
set -euo pipefail
set +x

cd "$(dirname "${BASH_SOURCE[0]}")/.."
ENV_FILE=".env"
# 第一个非选项参数才是 env 文件；避免把 --placeholder 当成文件名
if [ $# -gt 0 ] && [ "${1#-}" = "$1" ]; then
  ENV_FILE="$1"
fi

# --placeholder：给 `make jobs-test` 用。jenkins-jobs test 只在本地渲染 XML、
# 不连 Jenkins，所以没有 .env 也应该能跑（CI/新克隆场景）。
PLACEHOLDER=0
for arg in "$@"; do
  [ "$arg" = "--placeholder" ] && PLACEHOLDER=1
done

if [ ! -f "$ENV_FILE" ]; then
  if [ "$PLACEHOLDER" = "1" ]; then
    echo "提示：$ENV_FILE 不存在，本次使用占位值（仅本地渲染校验，不会连接 Jenkins）" >&2
    tmp_env="$(mktemp)"
    trap 'rm -f -- "$tmp_env"' EXIT
    printf 'JENKINS_URL=http://localhost:8080/jenkins\nJENKINS_ADMIN_ID=placeholder\nJENKINS_ADMIN_PASSWORD=placeholder\n' >"$tmp_env"
    ENV_FILE="$tmp_env"
  else
    echo "缺少 $ENV_FILE，请复制 .env.example 并填写 Jenkins 连接信息" >&2
    exit 1
  fi
fi

# Compose dotenv syntax is not shell syntax; parse it without executing .env.
python3 - "$ENV_FILE" <<'PY'
import os
from pathlib import Path
import re
import tempfile
import sys

keys = ("JENKINS_URL", "JENKINS_ADMIN_ID", "JENKINS_ADMIN_PASSWORD")
values = {}
for raw in Path(sys.argv[1]).read_text().splitlines():
    line = raw.strip()
    if not line or line.startswith("#"):
        continue
    if line.startswith("export "):
        line = line[7:].lstrip()
    key, sep, value = line.partition("=")
    key = key.strip()
    if not sep or key not in keys:
        continue
    value = value.strip()
    if value.startswith(("'", '"')):
        quote = value[0]
        end = value.find(quote, 1)
        if end == -1 or (value[end + 1:].strip() and
                         not value[end + 1:].strip().startswith("#")):
            sys.exit(f"{key}: 需要单行、正确闭合的引号")
        value = value[1:end]
    else:
        value = re.split(r"\s+#", value, maxsplit=1)[0].rstrip()
    values[key] = value

missing = [key for key in keys if not values.get(key)]
if missing:
    sys.exit("缺少必填变量: " + ", ".join(missing))
if any("\n" in value or "\r" in value or "\0" in value for value in values.values()):
    sys.exit("Jenkins 配置值必须为单行")

# JJB uses ConfigParser interpolation, so literal percent signs must be escaped.
content = re.sub(
    r"\$\{([^}]+)\}",
    lambda match: values[match.group(1)].replace("%", "%%"),
    Path("config/jenkins_jobs.ini.tpl").read_text(),
)
directory = Path(".jjb")
directory.mkdir(mode=0o700, exist_ok=True)
os.chmod(directory, 0o700)
temporary = None
try:
    with tempfile.NamedTemporaryFile(mode="w", dir=directory, delete=False) as handle:
        temporary = handle.name
        os.fchmod(handle.fileno(), 0o600)
        handle.write(content)
    os.replace(temporary, directory / "jenkins_jobs.ini")
finally:
    if temporary and os.path.exists(temporary):
        os.unlink(temporary)
print("已生成 .jjb/jenkins_jobs.ini (0600)")
PY
