#!/usr/bin/env bash
# M0 自举：初始化环境 -> 渲染路由 -> 分批启动并等待健康 -> 端点自检
set -euo pipefail
set +x
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
read -r -a COMPOSE_COMMAND <<< "${COMPOSE:-docker compose}"

PUSH_JOBS=0
SERVICE=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --push-jobs) PUSH_JOBS=1; shift ;;
    --service)
      if [ "$#" -lt 2 ] || [ -z "$2" ]; then
        echo "--service 需要指定服务名" >&2
        exit 1
      fi
      SERVICE="$2"; shift 2 ;;
    *) echo "未知参数: $1" >&2; exit 1 ;;
  esac
done

if [ "$PUSH_JOBS" = 1 ]; then
  if [ -n "$SERVICE" ]; then
    echo "--push-jobs 不能与 --service 同用" >&2
    exit 1
  fi
  exec make jobs
fi

case "$SERVICE" in
  ""|dnsmasq|jenkins|jenkins-agent|caddy|router|ldap|ldapadmin|dex|oauth2-proxy|homepage) ;;
  nexus) echo "nexus 已移出 compose（#46）：请跑 Jenkins job nexus-deploy，或直接 bash scripts/nexus-deploy.sh" >&2; exit 1 ;;
  *) echo "不支持的服务: $SERVICE" >&2; exit 1 ;;
esac
case "${ENV_NAME:-dev}" in
  dev) ENV_FILE="${ENV_FILE:-.env}" ;;
  staging|prod) ENV_FILE="${ENV_FILE:-.env.${ENV_NAME}}" ;;
  *) echo "ENV_NAME 必须为 dev / staging / prod" >&2; exit 1 ;;
esac

if [ -n "${SERVICE_VERSION:-}" ]; then
  # #46：唯一支持版本覆盖的 nexus 已经移出 compose，这条通道没有适用对象了。
  # 保留成硬错误而不是静默忽略 —— 传了却什么都没发生，是排查时最贵的一种"成功"。
  echo "SERVICE_VERSION 已停用（#46）：nexus 移出 compose，改由 Jenkins job nexus-deploy 部署；" >&2
  echo "镜像 digest 写在 scripts/nexus-deploy.sh 的 NEXUS_IMAGE 里。" >&2
  exit 1
fi
if [ -n "${SERVICE_PORT:-}" ]; then
  echo "SERVICE_PORT 已废弃（ADR-13 域名路由）：请在 $ENV_FILE 设置 GATEWAY_HTTP_PORT / GATEWAY_HTTPS_PORT" >&2
  exit 1
fi
if [ -n "${SERVICE_DOMAIN:-}" ]; then
  echo "SERVICE_DOMAIN 已废弃（ADR-13 域名路由）：请在 $ENV_FILE 设置 GATEWAY_DOMAIN" >&2
  exit 1
fi

if [ ! -f "$ENV_FILE" ]; then
  if [ -n "$SERVICE" ] || [ "$ENV_FILE" != .env ] || [ "${ENV_NAME:-dev}" != dev ]; then
    echo "缺少 $ENV_FILE；单服务/非 dev 部署需预先配置环境文件" >&2
    exit 1
  fi
  python3 - "$ENV_FILE" <<'PY'
import os
from pathlib import Path
import secrets
import string
import sys

values = {key: secrets.token_hex(32) for key in (
    "JENKINS_ADMIN_PASSWORD", "LDAP_ADMIN_PASSWORD", "OAUTH2_CLIENT_SECRET",
    # #46：Nexus 由 job 部署并改密，密码在这里生成，随 .env 落盘。
    "NEXUS_ADMIN_PASSWORD",
    # 目录 10 个初始账号共用的口令。仓库 LDIF 只存哈希、哈希对应的真值谁都不知道，
    # 所以必须在这里生成一份并留在 .env —— 否则新建目录后所有账号都登不进去。
    # 生成完还要跑 `make ldap-passwords` 让 LDIF 哈希与它一致。
    "ORGFLOW_INITIAL_PASSWORD",
)}
# 32 printable ASCII bytes; also a valid oauth2-proxy base64 cookie secret.
values["OAUTH2_COOKIE_SECRET"] = "".join(
    secrets.choice(string.ascii_letters + string.digits + "-_") for _ in range(32)
)
lines = Path(".env.example").read_text().splitlines(keepends=True)
found = set()
for index, line in enumerate(lines):
    key = line.partition("=")[0]
    if key in values:
        lines[index] = f"{key}={values[key]}\n"
        found.add(key)
if found != values.keys():
    sys.exit(".env.example 缺少必需的密钥字段")
fd = os.open(sys.argv[1], os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
with os.fdopen(fd, "w") as handle:
    handle.write("".join(lines))
print("已生成随机密钥，已写入 .env，请妥善保存（不在终端显示密码）。")
PY
fi

# agent 的 SSH 密钥（#45）：jenkins 与 jenkins-agent 都 bind 了 secrets/ 下的文件，
# 文件不存在时 compose 会以「bind source path does not exist」直接失败，
# 而且这个报错完全看不出是密钥没生成 —— 所以在任何 compose 调用之前先备好。
# 已存在就复用，不会覆盖现有密钥（覆盖等于所有 agent 立刻连不上）。
# 注意：这一步**不写 .env**，只产出 secrets/ 下的两个文件。
bash scripts/gen-agent-key.sh >/dev/null

# JCasC 用 directEntry 引用私钥，compose 里写的是**裸变量**
# （`- JENKINS_AGENT_SSH_PRIVATE_KEY`，不带 `=` 表示从宿主环境取值）。
# 所以必须在 compose 之前 export；写进 .env 会违反「已有 .env 绝不修改」的约定，
# 而且 dotenv 也不支持多行 PEM。
if [ -r "$ROOT/secrets/agent_ssh_key" ]; then
  JENKINS_AGENT_SSH_PRIVATE_KEY="$(cat "$ROOT/secrets/agent_ssh_key")"
  export JENKINS_AGENT_SSH_PRIVATE_KEY
fi

# agent 的 **host key 公钥**（不是上面那把登录用的私钥）。
# JCasC 的 manuallyProvidedKeyVerificationStrategy 要求「算法 + base64」两列，
# 而 .pub 的第三列是注释（`jenkins-agent-host@orgflow-devops`），带上就对不上，
# 所以这里切成前两列再 export。
# 为什么必须固定：容器重建后 /etc/ssh 不持久化，`ssh-keygen -A` 会重生成 host key，
# 节点就会因为 host key 变了而离线，等人手点「Trust SSH Host Key」才恢复。
if [ -r "$ROOT/secrets/agent_host_key.pub" ]; then
  JENKINS_AGENT_HOST_KEY="$(awk 'NR==1{print $1" "$2}' "$ROOT/secrets/agent_host_key.pub")"
  export JENKINS_AGENT_HOST_KEY
fi

# 空值不能放过去：ManuallyProvidedKeyVerificationStrategy 在构造时就 parseKey，
# 拿到空串会抛 IllegalArgumentException，JCasC 整份配置应用失败 —— 表现成
# Jenkins 起不来，而日志里只有一行 parse 错误，很难联想到这里。
if [ -z "${JENKINS_AGENT_HOST_KEY:-}" ]; then
  echo "✗ secrets/agent_host_key.pub 缺失或为空，JCasC 的 host key 校验会启动失败" >&2
  echo "  修：rm -f secrets/agent_host_key* && bash scripts/gen-agent-key.sh" >&2
  exit 1
fi

# docker.sock 的 gid 必须补给 agent 容器（理由见 docker-compose.yml 的 group_add 注释）。
# 和私钥同理：**export 到宿主环境**，不写 .env —— 既有「已有 .env 绝不修改」的约定，
# 而且这个值随宿主变化，写进 .env 会让 .env 在不同机器间不能复用。
DOCKER_GID="${DOCKER_GID:-$(stat -c %g /var/run/docker.sock 2>/dev/null || echo 0)}"
export DOCKER_GID

HEALTH_TIMEOUT="${DEPLOY_HEALTH_TIMEOUT:-600}"
POLL_INTERVAL="${DEPLOY_POLL_INTERVAL:-3}"
for value in "$HEALTH_TIMEOUT" "$POLL_INTERVAL"; do
  if [[ ! "$value" =~ ^[1-9][0-9]{0,5}$ ]]; then
    echo "DEPLOY_HEALTH_TIMEOUT / DEPLOY_POLL_INTERVAL 必须为正整数秒（最多六位）" >&2
    exit 1
  fi
done

COMPOSE_COMMAND+=(--env-file "$ENV_FILE")

# USE_GHCR=1 时镜像是 digest 锁定的，只能拉、不能建。
# 带 `build:` 的五个服务（dnsmasq / router / jjb / jenkins / jenkins-agent）一旦被 --build
# 强制重建，compose 会拿 `ghcr.io/...:tag@sha256:...` 当 tag 去写，直接报：
#   refusing to create a tag with a digest reference
# 所以构建标志必须跟着来源走，不能写死 --build。
if [ "${USE_GHCR:-0}" = 1 ]; then BUILD_FLAG="--no-build"; else BUILD_FLAG="--build"; fi

# 域名是渲染的输入：先解析 Compose 得到 GATEWAY_DOMAIN，再渲染 Caddyfile / dex 配置。
# 顺序反了的话，.env 改了域名而 Caddyfile 仍按 routes.yaml 的默认值生成。
if ! DEPLOY_CONFIG="$("${COMPOSE_COMMAND[@]}" config --format json 2>/dev/null)"; then
  echo "Compose 配置解析失败，请检查 $ENV_FILE 和 docker-compose.yml（错误正文可能含密钥，不输出）" >&2
  exit 1
fi
GATEWAY_DOMAIN="$(printf '%s' "$DEPLOY_CONFIG" | python3 -c '
import json, sys
config = json.load(sys.stdin)
env = config["services"]["router"].get("environment") or {}
print(env.get("GATEWAY_DOMAIN") or "org-devops.com")
')"
HTTPS_PORT="$(printf '%s' "$DEPLOY_CONFIG" | python3 -c '
import json, sys
ports = json.load(sys.stdin)["services"]["caddy"]["ports"]
print(next(p["published"] for p in ports if p["target"] == 443))
')"
HTTP_PORT="$(printf '%s' "$DEPLOY_CONFIG" | python3 -c '
import json, sys
ports = json.load(sys.stdin)["services"]["caddy"]["ports"]
print(next(p["published"] for p in ports if p["target"] == 80))
')"

mkdir -p out
# 认证站点域名由 routes.yaml 的 name: auth 路由决定，这里只注入域名后缀
export GATEWAY_DOMAIN
python3 services/router/render.py --routes config/routes.yaml --out out/Caddyfile --admin ""

# dex 的 issuer / redirectURI 必须是浏览器可达的绝对 URL，按当前域名渲染
if ! ENV_FILE="$ENV_FILE" GATEWAY_DOMAIN="$GATEWAY_DOMAIN" \
     bash "$ROOT/scripts/render-dex.sh" >/dev/null; then
  echo "dex 配置渲染失败（scripts/render-dex.sh）" >&2
  exit 1
fi

if [ -n "$SERVICE" ]; then
  echo "== 部署 $SERVICE (${ENV_NAME:-dev}) =="
  # 单服务默认沿用 compose 的「缺镜像才构建」，不强制重建；只有 GHCR（digest 锁定）必须 --no-build。
  if [ "${USE_GHCR:-0}" = 1 ]; then
    "${COMPOSE_COMMAND[@]}" up -d --no-deps --no-build "$SERVICE"
  else
    "${COMPOSE_COMMAND[@]}" up -d --no-deps "$SERVICE"
  fi
  "${COMPOSE_COMMAND[@]}" ps "$SERVICE"
  exit 0
fi

# Compose logs may contain credentials, including values supplied by the caller.
redact() {
  DEPLOY_CONFIG="$DEPLOY_CONFIG" python3 -c '
import json, os, sys
config = json.loads(os.environ["DEPLOY_CONFIG"])
secrets = set()
for service in config["services"].values():
    for key, value in service.get("environment", {}).items():
        if value and any(word in key.upper() for word in ("PASSWORD", "SECRET", "TOKEN")):
            secrets.add(str(value))
    for arg in service.get("command") or []:
        key, sep, value = arg.partition("=")
        if sep and value and any(word in key.lower() for word in ("password", "secret", "token")):
            secrets.add(value)
for line in sys.stdin:
    for secret in sorted(secrets, key=len, reverse=True):
        line = line.replace(secret, "[REDACTED]")
    sys.stdout.write(line)
    sys.stdout.flush()
'
}

diagnose() {
  echo "== 部署失败；相关服务: $* ==" >&2
  {
    "${COMPOSE_COMMAND[@]}" ps -a || echo "无法读取 docker compose ps" >&2
    "${COMPOSE_COMMAND[@]}" logs --tail=50 "$@" || echo "无法读取服务日志" >&2
  } 2>&1 | redact >&2
  echo "若尚未创建容器，则无日志；请查看上方对应服务的拉取/构建/启动错误。" >&2
}

wait_healthy() {
  local deadline=$((SECONDS + HEALTH_TIMEOUT))
  local svc id status pending
  while :; do
    pending=""
    for svc in "$@"; do
      if ! id="$("${COMPOSE_COMMAND[@]}" ps -a -q "$svc" 2>&1)"; then
        printf '%s\n' "$id" | redact >&2
        diagnose "$svc"
        return 1
      fi
      if [ -z "$id" ]; then
        echo "$svc: 未创建容器" >&2
        diagnose "$svc"
        return 1
      fi
      if ! status="$(docker inspect -f '{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{else}}missing-healthcheck{{end}}' "$id" 2>&1)"; then
        printf '%s\n' "$status" | redact >&2
        diagnose "$svc"
        return 1
      fi
      if [ "$status" != "running healthy" ]; then
        pending+="$svc ($status); "
        case "$status" in
          *missing-healthcheck*|exited*|dead*|*unhealthy*)
            echo "$svc: $status" >&2
            diagnose "$svc"
            return 1
            ;;
        esac
      fi
    done
    if [ -z "$pending" ]; then
      echo "== healthy: $* =="
      return 0
    fi
    if (( SECONDS >= deadline )); then
      echo "健康等待超时（${HEALTH_TIMEOUT}s）: $pending" >&2
      diagnose "$@"
      return 1
    fi
    echo "等待健康: $pending"
    sleep "$POLL_INTERVAL"
  done
}

start_batch() {
  local svc
  echo "== 启动批次: $* =="
  for svc in "$@"; do
    echo "-- 拉取/构建/启动 $svc"
    if ! "${COMPOSE_COMMAND[@]}" up -d --no-deps "$BUILD_FLAG" --quiet-pull "$svc" 2>&1 | redact; then
      diagnose "$svc"
      return 1
    fi
  done
  wait_healthy "$@"
}

# dnsmasq 必须最先起来：其余服务都配了 dns: 172.31.0.2
start_batch dnsmasq
start_batch ldap
start_batch dex oauth2-proxy
start_batch router caddy
start_batch jenkins jenkins-agent ldapadmin homepage
wait_healthy dnsmasq ldap dex oauth2-proxy router caddy jenkins jenkins-agent ldapadmin homepage

# agent 必须真的能连上宿主 daemon，否则三个 pipeline job 全是 pending 或假失败。
# agent 的 SSH 会话用户是 jenkins(1000)（镜像里 PermitRootLogin no）。
#
# ★ 检查方式必须走 `su`，不能用 `docker exec -u jenkins ...`：
#   docker exec 会继承容器 OCI spec 里的 AdditionalGids（也就是 group_add 的效果），
#   而 sshd 给登录会话调 initgroups()、按 /etc/group 重置附加组。
#   所以 `docker exec -u jenkins docker info` 即使在真机上 job 全挂也照样通过
#   —— 这个假阳性害我们多花了一轮真机验收（2026-11-01）。
#   su 和 sshd 一样走 initgroups()，是等价的判据。
if ! docker exec of-jenkins-agent su -s /bin/sh -c 'docker info' jenkins >/dev/null 2>&1; then
  echo "✗ agent 里 jenkins 用户的 SSH 会话连不上 /var/run/docker.sock（DOCKER_GID=${DOCKER_GID:-未设置}）" >&2
  echo "  job 会以「找不到网络 orgflow」这类假象失败。检查：" >&2
  echo "    stat -c %g /var/run/docker.sock                       # 宿主上的真实 gid" >&2
  echo "    docker exec of-jenkins-agent id -Gn jenkins           # jenkins 的附加组" >&2
  echo "    docker logs of-jenkins-agent | head -20               # 入口脚本有没有改 /etc/group" >&2
  exit 1
fi
echo "== agent 能驱动宿主 docker（gid ${DOCKER_GID:-未设置}，经 su 复核）=="

# 域名路由：所有自检都带 SNI/Host，走 127.0.0.1 的映射端口。
#
# URL 里**必须显式带端口**：--resolve 是按 host:port 精确匹配的，只写 https://host/
# 的话 curl 按隐式 443 去连，映射对不上就退回真实 DNS —— 报出来是「连接失败」，
# 看着像网关没起来，实际是自检自己把地址写错了。
# 默认 GATEWAY_HTTPS_PORT=443 时隐式端口恰好等于映射端口，所以这个 bug 只在
# 非 443 环境暴露（CI 用 8443、局域网自测常用 8443）。
gw() {   # gw <子域> <路径> → HTTP 状态码
  curl -sSk --connect-timeout 5 --max-time 10 -o /dev/null -w '%{http_code}' \
    --resolve "$1.${GATEWAY_DOMAIN}:${HTTPS_PORT}:127.0.0.1" \
    "https://$1.${GATEWAY_DOMAIN}:${HTTPS_PORT}$2"
}

# 给人看的 URL 则相反：443 是隐式默认值，带上只是噪音；非 443 不带就是错的地址，
# 复制出去必然打不开。所以显示用 VISIBLE_PORT，请求用上面的 gw()。
if [ "$HTTPS_PORT" = "443" ]; then VISIBLE_PORT=""; else VISIBLE_PORT=":${HTTPS_PORT}"; fi

# 期望值说明（#86 之后）：
#   jenkins /  → 403 或 302 都算「没给内容」。Jenkins 自 #86 起直连 LDAP 自带登录、
#                网关不再转发 auth，匿名访问根路径由 Jenkins 自己回 403；旧值写死 302
#                会让任何正确的 #86 环境必然红（2026-11-11 真机复现）。
#   jenkins /login → 200，这才是「反代通、应用活着、能登录」的正面判据。
# 期望值用 `|` 分隔表示「任一命中即通过」。
for check in "auth /ping 200" "jenkins /login 200" "jenkins / 302|403" "home / 200"; do
  read -r sub path expected <<< "$check"
  url="https://${sub}.${GATEWAY_DOMAIN}${VISIBLE_PORT}${path}"
  if ! actual="$(gw "$sub" "$path")"; then
    echo "端点自检连接失败: $url（宿主端口 ${HTTPS_PORT}）" >&2
    diagnose caddy oauth2-proxy
    exit 1
  fi
  if [[ "|${expected}|" != *"|${actual}|"* ]]; then
    echo "端点自检失败: $url，预期 $expected，实际 $actual" >&2
    diagnose caddy oauth2-proxy
    exit 1
  fi
  echo "端点自检通过: $url = $actual"
done

echo "== 部署完成：compose 侧全部服务 healthy =="
echo "网关端口：HTTP ${HTTP_PORT} / HTTPS ${HTTPS_PORT}（宿主映射）"
echo "访问入口（需要先让域名解析到本机）："
echo "  https://jenkins.${GATEWAY_DOMAIN}${VISIBLE_PORT}/     自带登录（#86）：未登录 403，登录页 /login = 200"
echo "  https://nexus.${GATEWAY_DOMAIN}${VISIBLE_PORT}/       Nexus 由 job 部署（#46），未跑过 nexus-deploy 时是 502；跑过后是 200"
echo "  https://ldapadmin.${GATEWAY_DOMAIN}${VISIBLE_PORT}/     自带 LDAP 登录（#86）：未登录 200 是登录页"
echo "  https://auth.${GATEWAY_DOMAIN}${VISIBLE_PORT}/ping    认证网关"
echo "  https://dex.${GATEWAY_DOMAIN}${VISIBLE_PORT}/dex/     OIDC"
echo "  https://home.${GATEWAY_DOMAIN}${VISIBLE_PORT}/        统一入口（所有服务的卡片）"
echo "域名解析：bash scripts/gen-hosts.sh      生成 /etc/hosts 片段"
echo "证书信任：bash scripts/ca-install.sh     安装 Caddy 内部 CA 根证书"
echo "下一步: make jobs（先配置 Jenkins 插件、API 管理入口及 GitHub 凭据）"
echo "       然后跑 Jenkins job nexus-deploy（或 bash scripts/nexus-deploy.sh）把 Nexus 拉起来"
echo "Jenkins 管理员密码在 $ENV_FILE 的 JENKINS_ADMIN_PASSWORD"
if ! grep -qE '^NEXUS_ADMIN_PASSWORD=.+' "$ENV_FILE" 2>/dev/null; then
  echo "⚠ $ENV_FILE 没有 NEXUS_ADMIN_PASSWORD：nexus-deploy 会跳过改密，" >&2
  echo "  Nexus 将停在「界面强制改初始密码」的状态。老环境请手动补上这两行：" >&2
  echo "    NEXUS_ADMIN_ID=admin" >&2
  echo "    NEXUS_ADMIN_PASSWORD=<你的密码>" >&2
fi
