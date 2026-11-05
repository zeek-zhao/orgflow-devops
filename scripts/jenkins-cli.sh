#!/usr/bin/env bash
# Jenkins CLI 四件套：list / get / run / log
#
# 为什么存在：Jenkins 的 Remote Access API 是运维面的编排入口，但 213 上 8080
# 不发布到宿主、站点又被网关 forward_auth 包住（会话交接 §4.5）——打
# https://jenkins.<domain> 只会拿到 302，API 请求根本到不了 Jenkins。
# 这个脚本直连容器固定 IP，用 HTTP Basic（API token 位）鉴权，每步回显请求
# 与结果；任何一步失败都非 0 退出并给出明确信息，绝不静默成功。
#
# 凭据纪律：只读环境变量或 ~/workbuddy/orgflow-devops/.env，
# 绝不写进脚本 / 日志 / 文档；显式 set +x 防调试回显；请求回显只打
# method + URL，不打 Authorization；curl 的凭据走 stdin config，不进 argv，
# 语义等价于官方 `--user USER:TOKEN`。
#
# 路径来源（资料诚实，勿改口径）：
#   - buildWithParameters：Jenkins Remote Access API 官方逐字示例
#     `curl JENKINS_URL/job/JOB_NAME/buildWithParameters --user USER:TOKEN --data id=123 --data verbosity=high`，
#     且官方原话 "API tokens are preferred instead of crumbs for CSRF protection."
#   - /api/json、/job/<job>/api/json、/job/<job>/<build>/consoleText：
#     该官方页**没有逐字给出**这些 endpoint（只写了 `.../api/` 模式与
#     wrapper 的 progressiveText），路径是在 213 运行时实测确认的，
#     见 docs/services/jenkins.md 的「运行时确认」段，不得写成「官方文档规定」。
#
# 用法：bash scripts/jenkins-cli.sh --help
set -euo pipefail
set +x   # 绝不打开：执行轨迹回显会把 Basic 凭据带出来

BASE_URL="${JENKINS_CLI_URL:-http://172.31.0.20:8080}"
BASE_URL="${BASE_URL%/}"
ENV_FILE="${JENKINS_CLI_ENV_FILE:-$HOME/workbuddy/orgflow-devops/.env}"

AUTH_B64=""
CREDS_LOADED=0

TMP_BODY="$(mktemp)"
TMP_CODE="$(mktemp)"
TMP_HEADERS="$(mktemp)"
trap 'rm -f -- "$TMP_BODY" "$TMP_CODE" "$TMP_HEADERS"' EXIT

usage() {
  cat <<'USAGE'
用法：bash scripts/jenkins-cli.sh <子命令> [参数]

  list                      列出所有 Job（GET /api/json）
  get <job>                 取 Job 详情 JSON（GET /job/<job>/api/json）
  run <job> [KEY=VAL ...]   带参数触发（POST /job/<job>/buildWithParameters）
  log <job> <build|last>    下载构建日志（GET /job/<job>/<build>/consoleText，last=lastBuild）

连接：
  JENKINS_CLI_URL       默认 http://172.31.0.20:8080（容器固定 IP；
                         不要设成网关域名，forward_auth 会把请求 302 到 Dex）
  JENKINS_CLI_ENV_FILE  凭据文件，默认 ~/workbuddy/orgflow-devops/.env

凭据：
  JENKINS_ADMIN_ID / JENKINS_ADMIN_PASSWORD，优先环境变量，其次上面的 .env。
  绝不写进脚本、日志或文档。HTTP Basic + API token，不使用 crumb。
USAGE
}

fail() {
  echo "✗ $*" >&2
  exit 1
}

urlencode() {
  python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$1"
}

# 惰性加载：参数校验不需要凭据，只有真正发请求时才读。
ensure_credentials() {
  if (( CREDS_LOADED )); then
    return 0
  fi
  if [[ -z "${JENKINS_ADMIN_ID:-}" || -z "${JENKINS_ADMIN_PASSWORD:-}" ]]; then
    [[ -f "$ENV_FILE" ]] || fail "找不到凭据文件 $ENV_FILE；也可直接 export JENKINS_ADMIN_ID / JENKINS_ADMIN_PASSWORD"
    # Compose dotenv 不是 shell 语法，不能 source；用 python3 解析，只取值。
    local parsed
    parsed="$(python3 - "$ENV_FILE" <<'PYCREDS'
import re
import sys
from pathlib import Path

keys = ("JENKINS_ADMIN_ID", "JENKINS_ADMIN_PASSWORD")
values = {}
for raw in Path(sys.argv[1]).read_text(encoding="utf-8").splitlines():
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
        if end == -1:
            sys.exit(key + ": 引号未闭合")
        value = value[1:end]
    else:
        value = re.split(r"\s+#", value, maxsplit=1)[0].rstrip()
    values[key] = value
for key in keys:
    if any(c in values.get(key, "") for c in "\r\n\0"):
        sys.exit(key + ": 必须为单行")
# 只把值交给 shell 变量，不打印给人看、不写日志。
print(values.get("JENKINS_ADMIN_ID", ""))
print(values.get("JENKINS_ADMIN_PASSWORD", ""))
PYCREDS
)" || fail "解析 $ENV_FILE 失败"
    local -a creds
    mapfile -t creds <<< "$parsed"
    JENKINS_ADMIN_ID="${JENKINS_ADMIN_ID:-${creds[0]:-}}"
    JENKINS_ADMIN_PASSWORD="${JENKINS_ADMIN_PASSWORD:-${creds[1]:-}}"
  fi
  [[ -n "$JENKINS_ADMIN_ID" && -n "$JENKINS_ADMIN_PASSWORD" ]] || \
    fail "凭据为空：JENKINS_ADMIN_ID / JENKINS_ADMIN_PASSWORD"
  AUTH_B64="$(printf '%s:%s' "$JENKINS_ADMIN_ID" "$JENKINS_ADMIN_PASSWORD" | base64 | tr -d '\n')"
  CREDS_LOADED=1
}

# 统一发请求：打印请求（脱敏）与结果；非 2xx 一律非 0 退出并给明确信息。
request() {
  local method="$1" path="$2"
  shift 2
  local url="$BASE_URL$path"
  ensure_credentials
  echo ">>> $method $url"
  local curl_rc=0 code
  # Basic 凭据通过 stdin config 注入 header，不进 argv / 回显 / 日志。
  printf 'header = "Authorization: Basic %s"\n' "$AUTH_B64" \
    | curl --config - -sS -g --connect-timeout 5 --max-time 30 \
        -X "$method" -D "$TMP_HEADERS" -o "$TMP_BODY" -w '%{http_code}' \
        "$@" "$url" > "$TMP_CODE" || curl_rc=$?
  code="$(cat "$TMP_CODE")"
  if [[ $curl_rc -ne 0 ]]; then
    echo "✗ 请求失败：curl 退出码 $curl_rc（$method $url）；检查 $BASE_URL 是否可达" >&2
    return "$curl_rc"
  fi
  echo "<<< HTTP $code"
  cat "$TMP_BODY"
  echo
  if ! [[ "$code" =~ ^2[0-9][0-9]$ ]]; then
    case "$code" in
      401)     echo "✗ 认证失败（HTTP 401）：JENKINS_ADMIN_ID / JENKINS_ADMIN_PASSWORD（API token 位）不正确" >&2 ;;
      403)     echo "✗ 认证/授权失败（HTTP 403）：凭据无效、权限不足，或 CSRF crumb 未豁免（官方推荐 API token；若用账号密码做 Basic auth，POST 会被要求 crumb）。响应体见上。" >&2 ;;
      404)     echo "✗ 资源不存在（HTTP 404）：$url" >&2 ;;
      *)       echo "✗ 请求被拒绝（HTTP $code）：$url" >&2 ;;
    esac
    return 1
  fi
  return 0
}

cmd_list() {
  [[ $# -eq 0 ]] || fail "list 不接受参数；用法：jenkins-cli.sh list"
  # /api/json：运行时确认路径（官方页只给出 `.../api/` 模式）
  request GET '/api/json?tree=jobs[name,url,color]' || return $?
  echo "✓ list 完成"
}

cmd_get() {
  [[ $# -eq 1 ]] || fail "get 需要一个 Job 名；用法：jenkins-cli.sh get <job>"
  local job="$1"
  [[ -n "$job" ]] || fail "Job 名不能为空"
  local job_enc
  job_enc="$(urlencode "$job")"
  # /job/<job>/api/json：运行时确认路径
  request GET "/job/$job_enc/api/json" || return $?
  echo "✓ get 完成（$job）"
}

cmd_run() {
  [[ $# -ge 1 ]] || fail "run 需要 Job 名；用法：jenkins-cli.sh run <job> [KEY=VAL...]"
  local job="$1"
  shift
  [[ -n "$job" ]] || fail "Job 名不能为空"
  local -a data=()
  local kv
  for kv in "$@"; do
    [[ "$kv" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] || fail "参数格式必须是 KEY=VAL（收到：$kv）"
    data+=(--data-urlencode "$kv")
  done
  local job_enc
  job_enc="$(urlencode "$job")"
  # 官方逐字示例：POST JENKINS_URL/job/JOB_NAME/buildWithParameters
  #   + --user USER:TOKEN --data id=123 --data verbosity=high
  # 实现用 --data-urlencode（对 VAL 做 URL 编码，语义等价且更健壮）。
  request POST "/job/$job_enc/buildWithParameters" "${data[@]}" || return $?
  local loc
  loc="$(awk 'tolower($1)=="location:" {print $2}' "$TMP_HEADERS" | tr -d '\r' | tail -1 || true)"
  if [[ -n "$loc" ]]; then
    echo "✓ run 已入队，Location: $loc"
  else
    echo "✓ run 完成（响应未带 Location 头）"
  fi
}

cmd_log() {
  [[ $# -eq 2 ]] || fail "log 需要 Job 名与构建号；用法：jenkins-cli.sh log <job> <build|last>"
  local job="$1" build="$2"
  [[ -n "$job" ]] || fail "Job 名不能为空"
  [[ -n "$build" ]] || fail "构建号不能为空（用 last 或数字）"
  local build_seg="$build"
  if [[ "$build" == "last" ]]; then
    build_seg="lastBuild"
  fi
  local job_enc build_enc
  job_enc="$(urlencode "$job")"
  build_enc="$(urlencode "$build_seg")"
  # /job/<job>/<build>/consoleText：运行时确认路径
  request GET "/job/$job_enc/$build_enc/consoleText" || return $?
  echo "✓ log 完成（$job $build）"
}

main() {
  local cmd="${1:-}"
  if [[ -z "$cmd" || "$cmd" == "-h" || "$cmd" == "--help" || "$cmd" == "help" ]]; then
    usage
    if [[ -z "$cmd" ]]; then
      exit 1
    fi
    exit 0
  fi
  case "$cmd" in
    list|get|run|log) shift ;;
    *) echo "✗ 未知子命令：$cmd" >&2; usage >&2; exit 1 ;;
  esac
  case "$cmd" in
    list) cmd_list "$@" ;;
    get)  cmd_get "$@" ;;
    run)  cmd_run "$@" ;;
    log)  cmd_log "$@" ;;
  esac
}

main "$@"
