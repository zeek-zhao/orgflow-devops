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
    printf 'JJB_JENKINS_URL=http://jenkins:8080/\nJENKINS_ADMIN_ID=placeholder\nJENKINS_ADMIN_PASSWORD=placeholder\n' >"$tmp_env"
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

keys = ("JJB_JENKINS_URL", "JENKINS_ADMIN_ID", "JENKINS_ADMIN_PASSWORD",
        "JJB_USER", "JJB_PASSWORD", "ORGFLOW_INITIAL_PASSWORD")
# jjb 容器在 compose 网络内直连 jenkins 服务（#30），不走网关/oauth2/TLS。
# 旧 .env 里的 JENKINS_URL 是浏览器/JCasC 用的对外地址，与 JJB 连接地址无关，
# 缺 JJB_JENKINS_URL 时用内网默认值，不再要求单独配置。
default_values = {"JJB_JENKINS_URL": "http://jenkins:8080/"}
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
for key, fallback in default_values.items():
    values.setdefault(key, fallback)

# #140 / #86：Jenkins 对外是 LDAP-only realm，没有本地 admin 账号。
# 全新部署的 .env 只带 ORGFLOW_INITIAL_PASSWORD，旧写法会拿 JENKINS_ADMIN_ID=admin
# 去连 Jenkins，首次 make jobs 必然 401。这里把「当前部署真正可用的凭据」归一化到
# ini 模板引用的 JENKINS_ADMIN_ID / JENKINS_ADMIN_PASSWORD 两个键：
#   1) 显式 JJB_USER / JJB_PASSWORD —— 运维换成专用服务账号；
#   2) 有 ORGFLOW_INITIAL_PASSWORD —— 用 LDAP bootstrap 建好的 svc-platform-admin
#      + 初始口令（make jobs 因此开箱即用，不再要求手工覆盖凭据）；
#   3) 都没有 —— 沿用 JENKINS_ADMIN_ID / JENKINS_ADMIN_PASSWORD（旧部署）。
# 归一化后才做必填校验，避免「给了 JJB_USER/JJB_PASSWORD 却仍报缺少必填变量」。
override_user = values.get("JJB_USER")
override_password = values.get("JJB_PASSWORD")
if override_user and override_password:
    values["JENKINS_ADMIN_ID"] = override_user
    values["JENKINS_ADMIN_PASSWORD"] = override_password
elif values.get("ORGFLOW_INITIAL_PASSWORD"):
    values["JENKINS_ADMIN_ID"] = "svc-platform-admin"
    values["JENKINS_ADMIN_PASSWORD"] = values["ORGFLOW_INITIAL_PASSWORD"]

missing = [key for key in ("JJB_JENKINS_URL", "JENKINS_ADMIN_ID", "JENKINS_ADMIN_PASSWORD")
           if not values.get(key)]
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
