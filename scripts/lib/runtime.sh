#!/usr/bin/env bash
# lib/runtime.sh —— 所有脚本共用的运行期工具函数（被 source，不单独执行）。
#
# 只解决三件事：
#   1. 从 config/ 读事实（不 grep .env、不写死 IP/端口/容器名）；
#   2. export compose 需要的透传变量（agent 密钥、docker gid）；
#   3. 统一「判健康 / 脱敏日志 / 失败诊断」的写法，避免每个脚本各写一套。
set -euo pipefail

ORGROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PY_LIB="$ORGROOT/scripts/lib"

orgflow_fail() {
  echo "✗ $*" >&2
  exit 1
}

orgflow_runtime_env() {
  printf '%s\n' "${RUNTIME_ENV:-$ORGROOT/out/runtime.env}"
}

# 调 python 配置库：orgflow_py <子命令> [参数...]
orgflow_py() {
  PYTHONPATH="$PY_LIB" python3 - "$@" <<'PY'
import sys
import config as cfgmod

cmd, rest = sys.argv[1], sys.argv[2:]
cfg = cfgmod.load()
services = cfgmod.load_services()

if cmd == "start-order":
    print("\n".join(cfgmod.start_order(services)))
elif cmd == "service-field":
    name, field = rest
    spec = (services.get("services") or {}).get(name)
    if spec is None:
        sys.exit(f"未知服务：{name}（见 config/services.yml）")
    print(spec.get(field, ""))
elif cmd == "container":
    name = rest[0]
    for group in ("services", "tools", "external"):
        spec = (services.get(group) or {}).get(name)
        if spec:
            print(spec["container"])
            break
    else:
        sys.exit(f"未知服务：{name}")
elif cmd == "services":
    print("\n".join((services.get("services") or {}).keys()))
elif cmd == "site":
    print(cfgmod.site(cfg, rest[0]))
elif cmd == "env":
    pairs = cfgmod.env_pairs(cfg, services)
    for key in rest:
        print(pairs.get(key, ""))
elif cmd == "json":
    import json
    print(json.dumps({"config": cfg, "services": services}, ensure_ascii=False))
elif cmd == "admin-dn":
    print(cfgmod.admin_dn(cfg))
elif cmd == "base-dn":
    print(cfgmod.base_dn(cfg))
elif cmd == "users-dn":
    print(cfgmod.users_dn(cfg))
else:
    sys.exit(f"未知子命令：{cmd}")
PY
}

orgflow_start_order() {
  orgflow_py start-order
}

orgflow_service_field() {
  orgflow_py service-field "$@"
}

# compose 里登记的服务名（不含 tools / external）
orgflow_services() {
  orgflow_py services
}

orgflow_container() {
  orgflow_py container "$@"
}

# 从配置取一个渲染后的值（与 compose 看到的完全一致）
orgflow_env_value() {
  orgflow_py env "$@"
}

# 把 out/runtime.env 读进当前 shell（供脚本内直接使用 $GATEWAY_DOMAIN 等）
orgflow_load_runtime_env() {
  local file
  file="$(orgflow_runtime_env)"
  [ -f "$file" ] || orgflow_fail "缺少 $file；先跑 bash scripts/10-render-config.sh（make render）"
  set -a
  # shellcheck disable=SC1090
  . "$file"
  set +a
}

# compose 需要的**透传**变量：agent 私钥 / host key 公钥 / docker.sock 的 gid。
#
# 为什么这些不进配置文件：都是「机器自身的属性」，换个宿主就变（gid），
# 或者是大段 PEM（私钥）。写进配置会让配置在不同机器间不能复用，
# 而 dotenv 格式也不支持多行值。
orgflow_export_runtime_env() {
  local key="$ORGROOT/secrets/agent_ssh_key"
  local pub="$ORGROOT/secrets/agent_host_key.pub"
  if [ -r "$key" ]; then
    JENKINS_AGENT_SSH_PRIVATE_KEY="$(cat "$key")"
    export JENKINS_AGENT_SSH_PRIVATE_KEY
  fi
  if [ -r "$pub" ]; then
    # JCasC 的 manuallyProvidedKeyVerificationStrategy 要「算法 + base64」两列，
    # 第三列注释带上就对不上，所以切前两列。
    JENKINS_AGENT_HOST_KEY="$(awk 'NR==1{print $1" "$2}' "$pub")"
    export JENKINS_AGENT_HOST_KEY
  fi
  if [ -z "${JENKINS_AGENT_HOST_KEY:-}" ]; then
    orgflow_fail "secrets/agent_host_key.pub 缺失或为空（JCasC 的 host key 校验会启动失败）；修：bash scripts/40-gen-agent-key.sh"
  fi
  DOCKER_GID="${DOCKER_GID:-$(stat -c %g /var/run/docker.sock 2>/dev/null || echo 0)}"
  export DOCKER_GID
}

# 日志脱敏：把 compose 配置里所有 PASSWORD/SECRET/TOKEN 的值替换掉再输出。
# 直接打日志会把口令写进 CI 日志与终端历史，属于审计事故。
orgflow_redact() {
  local compose_json
  compose_json="$(cat "${ORGROOT}/out/runtime.env" | sed '/^#/d' || true)"
  ORGFLOW_SECRETS="$compose_json" python3 -c '
import os, sys
secrets = []
def unquote(raw):
    # runtime.env 里含逗号/空格的值是带双引号的（见 scripts/lib/rendered_values.py），
    # 脱敏要拿真值去比，不能拿带引号的字面量 —— 否则日志里的口令不会被替换。
    if len(raw) >= 2 and raw[0] == raw[-1] == chr(34):
        return raw[1:-1].replace(chr(92) + chr(34), chr(34)).replace(chr(92) * 2, chr(92))
    return raw

for line in os.environ.get("ORGFLOW_SECRETS", "").splitlines():
    key, sep, value = line.partition("=")
    if sep and value and key.endswith(("PASSWORD", "SECRET", "TOKEN")):
        secrets.append(unquote(value))
for line in sys.stdin:
    for secret in sorted(secrets, key=len, reverse=True):
        line = line.replace(secret, "[REDACTED]")
    sys.stdout.write(line)
    sys.stdout.flush()
'
}

orgflow_diagnose() {
  local svc="$1"
  local runtime
  runtime="$(orgflow_runtime_env)"
  echo "== 失败诊断：$svc ==" >&2
  {
    docker compose --env-file "$runtime" -f "$ORGROOT/docker-compose.yml" ps -a || true
    docker compose --env-file "$runtime" -f "$ORGROOT/docker-compose.yml" logs --tail=50 "$svc" || true
  } 2>&1 | orgflow_redact >&2
}

orgflow_wait_healthy() {
  local svc="$1" timeout="${2:-120}"
  local container deadline id status
  container="$(orgflow_container "$svc")"
  deadline=$((SECONDS + timeout))
  while :; do
    id="$(docker ps -aq --filter "name=^${container}$" || true)"
    if [ -z "$id" ]; then
      echo "  $svc: 容器 $container 不存在" >&2
      return 1
    fi
    status="$(docker inspect -f '{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{else}}no-healthcheck{{end}}' "$id" 2>/dev/null || echo unknown)"
    case "$status" in
      "running healthy"|"running no-healthcheck") return 0 ;;
      *exited*|*dead*|*unhealthy*)
        echo "  $svc: $status" >&2
        return 1 ;;
    esac
    if (( SECONDS >= deadline )); then
      echo "  $svc: 等待健康超时（${timeout}s），最后状态 $status" >&2
      return 1
    fi
    # 轮询间隔可调：测试与 CI 里 mock 的健康状态是瞬时的，sleep 3 会白等
    sleep "${ORGROFLOW_POLL_INTERVAL:-3}"
  done
}
