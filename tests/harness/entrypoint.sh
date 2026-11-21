#!/usr/bin/env bash
set -Eeuo pipefail
set +x
export DOCKER_HOST=unix:///var/run/docker.sock
unset DOCKER_CONTEXT
# 域名路由（ADR-13）：测试栈固定 org-devops.com，网关端口用非特权端口避免占宿主 80/443
export GATEWAY_DOMAIN="${GATEWAY_DOMAIN:-org-devops.com}"
export GW_DOMAIN="$GATEWAY_DOMAIN"
export GW_HOST=127.0.0.1
export GW_HTTP_PORT=8080
export GW_HTTPS_PORT=8443
export M0_REPO=/repo
export M0_ENV_FILE=/repo/.env
export M0_COMPOSE_OVERRIDE=/tmp/m0-images.json
compose_ready=0
daemon_pid=
stage="starting dockerd"

compose() {
    local args=(-f /repo/docker-compose.yml)
    if [[ -n ${M0_COMPOSE_EXTRA:-} ]]; then args+=(-f "$M0_COMPOSE_EXTRA"); fi
    docker compose "${args[@]}" -f "$M0_COMPOSE_OVERRIDE" \
        --env-file "$M0_ENV_FILE" --project-directory /repo "$@"
}

# 同一套 compose 参数的可传递形式：scripts/*.sh 走 `COMPOSE` 环境变量约定
# （与 backup.sh 一致 —— shell 函数没法跨进程传给脚本）。
compose_cmd_string() {
    local parts="docker compose -f /repo/docker-compose.yml"
    if [[ -n ${M0_COMPOSE_EXTRA:-} ]]; then parts+=" -f $M0_COMPOSE_EXTRA"; fi
    parts+=" -f $M0_COMPOSE_OVERRIDE --project-directory /repo"
    printf '%s' "$parts"
}

diagnose() {
    echo "== failed: $stage ==" >&2
    if (( compose_ready )); then
        compose ps -a >&2 || echo "compose ps failed" >&2
        # ★ 必须滤掉 Java 栈帧：Jenkins 的启动异常有几十层 `at ...`，
        #   `--tail=50` 会全被栈帧占满，真正的错误行反而被挤掉了。
        compose logs --no-color --tail=200 2>&1 | grep -vE '^[^|]*\|[[:space:]]+at ' | tail -120 >&2 \
            || echo "compose logs failed" >&2
    fi
    tail -50 /var/log/dockerd.log >&2
}

cleanup() {
    local status=$?
    trap - EXIT
    set +e
    if (( status != 0 )); then diagnose; fi
    # Nexus 不是 compose 服务（#46），`compose down -v` 管不到它：
    # 容器还挂在 orgflow 网络上时 down 删不掉网络，卷也删不掉，
    # 报出来只是 "network has active endpoints"，看着像测试栈没清干净。
    docker rm -f of-nexus >/dev/null 2>&1 || true
    if [[ ${KEEP:-0} == 1 ]]; then
        echo "KEEP=1: preserving inner containers and m0-dind data; harness stays available for docker exec."
        echo "Stop the harness explicitly after inspection; rerun without KEEP to clean the inner stack."
        trap 'kill "$daemon_pid"; wait "$daemon_pid"; exit "$status"' TERM INT
        wait "$daemon_pid"
    else
        if (( compose_ready )); then
            compose down -v || { echo "inner compose cleanup failed" >&2; status=1; }
        fi
        # Nexus 卷也不在 compose 声明里（nexus-deploy.sh 自建）——m0-dind 是持久
        # 命名卷，不清的话下一次本地重跑会撞上上次已改密的 nexus-data：配置密码
        # 登录失败且 admin.password 已删，nexus 部署 stage 必红（2026-11-15 213
        # 实测；CI 是全新 runner 所以永远撞不到）。
        docker volume rm orgflow-devops_nexus_data >/dev/null 2>&1 || true
        if [[ -n $daemon_pid ]]; then
            kill "$daemon_pid"
            wait "$daemon_pid"
        fi
    fi
    exit "$status"
}
trap cleanup EXIT
trap 'echo "command failed in $stage (line $LINENO)" >&2' ERR
trap 'exit 130' INT
trap 'exit 143' TERM

dockerd --host=unix:///var/run/docker.sock --data-root=/var/lib/docker >/var/log/dockerd.log 2>&1 &
daemon_pid=$!
deadline=$((SECONDS + 90))
until docker info >/dev/null 2>&1; do
    if ! kill -0 "$daemon_pid" 2>/dev/null || (( SECONDS >= deadline )); then
        echo "dockerd did not become ready within 90s" >&2
        exit 1
    fi
    sleep 1
done

stage="preparing environment"
umask 077
#
# 测试栈的 env 文件（/tmp/m0.env）**只有一个真源**：config/orgflow.yml +
# config/services.yml，经 scripts/10-render-config.sh 渲染。
#
# 为什么不能拿 .env.example 当基础（2026-11-22 本地 DinD 实测）：它只有配置的
# 一小部分 —— 没有 LDAP_BASE_DN / LDAP_ADMIN_DN（ldap healthcheck 拿空 DN 去
# bind，容器日志 `op=0 BIND dn=""` + err 49，永久 unhealthy），也没有
# NETWORK_SUBNET / IP_*（compose 把这些 ${VAR} 逐个插值成空串，网络与固定 IP
# 全靠默认值，于是测试栈和真机的拓扑根本不是同一个）。
#
# 调用方显式提供了 .env（真机场景）时，只沿用它的【值】，不沿用它的文件：
# 缺哪些键就让渲染补哪些，这样 CI 与真机走同一条链。渲染结果落在
# /tmp/m0.env，绝不改仓库里的 .env。
source_env=$M0_ENV_FILE
M0_ENV_FILE=/tmp/m0.env

stage="rendering runtime config"
bash /repo/scripts/10-render-config.sh >/tmp/render.log 2>&1 || {
  cat /tmp/render.log >&2
  echo "配置渲染失败（config/orgflow.yml / config/services.yml）" >&2
  exit 1
}
umask 077
cp /repo/out/runtime.env "$M0_ENV_FILE"
chmod 600 "$M0_ENV_FILE"

# 口令类键：调用方 .env 自己给了就覆盖（尊重「已有 .env 不擅自改」的约定）
if [ -r "$source_env" ]; then
  while IFS= read -r assignment; do
    key=${assignment%%=*}
    case $key in
      *PASSWORD*|*SECRET*|*TOKEN*)
        if grep -qE "^${key}=" "$M0_ENV_FILE"; then
          python3 - "$M0_ENV_FILE" "$key" "$assignment" <<'PY'
import pathlib, sys
path, key, assignment = sys.argv[1], sys.argv[2], sys.argv[3]
lines = pathlib.Path(path).read_text(encoding="utf-8").splitlines()
out = [assignment if line.startswith(key + "=") else line for line in lines]
path.write_text("\n".join(out) + "\n", encoding="utf-8")
PY
          fi
        ;;
    esac
  done < <(grep -E '^[A-Z_]+=.+' "$source_env" || true)
fi
# 测试栈固定域名与端口：不受调用方配置影响（非特权端口，避免占宿主 80/443）
cat >> "$M0_ENV_FILE" <<EOF
GATEWAY_DOMAIN=$GATEWAY_DOMAIN
GATEWAY_HTTP_PORT=$GW_HTTP_PORT
GATEWAY_HTTPS_PORT=$GW_HTTPS_PORT
EOF

# 被测脚本（30-up-serial / 60-verify / backup…）自己会读 out/runtime.env，
# 所以它必须就是测试栈真正在用的那份变量，否则「脚本读 80/443、栈发布在
# 8080/8443」这种错位会以莫名其妙的自检失败出现。
cp "$M0_ENV_FILE" /repo/out/runtime.env
chmod 600 /repo/out/runtime.env
echo "[harness] env 键数=$(grep -c '=' "$M0_ENV_FILE")" >&2
if ! grep -qE '^LDAP_BASE_DN=.' "$M0_ENV_FILE"; then
  echo "[harness] ✗ 测试栈 env 文件里没有 LDAP_BASE_DN（配置渲染有问题？）" >&2
  exit 1
fi

# 渲染产物必须覆盖 compose 里出现的每个 ${VAR}，否则 compose 会把它插值成空串
# 而只打一行 warning —— 症状是「服务起来了但连不上」，排查成本极高。
stage="checking rendered vars"
missing=$(python3 - "$M0_ENV_FILE" <<'PY'
import pathlib, re, sys
env_file = pathlib.Path(sys.argv[1])
have = set()
for line in env_file.read_text(encoding="utf-8").splitlines():
    match = re.match(r"^([A-Za-z_][A-Za-z0-9_]*)=", line)
    if match:
        have.add(match.group(1))
needed = set()
# 只扫 compose 文件：scripts/*.sh、.github/workflows/*.yml、docs 里也有 ${VAR}，
# 但那些是 shell 变量或 CI 环境，不属于渲染产物要提供的键集（2026-11-22 实测：
# 扫全仓会报出 BASE_SHA / GITHUB_REPOSITORY / ae 等一堆假缺口）。
compose_files = [pathlib.Path("/repo/docker-compose.yml")]
for line in compose_files[0].read_text(encoding="utf-8").splitlines():
    match = re.match(r"^\s*-\s+([\w./-]+\.ya?ml)\s*$", line)
    if match:
        compose_files.append(pathlib.Path("/repo") / match.group(1))
for path in compose_files:
    if not path.exists():
        continue
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        if line.lstrip().startswith("#"):
            continue
        needed |= set(re.findall(r"\$\{([A-Za-z_][A-Za-z0-9_]*)", line))
# compose 项目层面的变量由调用方环境提供，不算渲染缺口
skip = {"COMPOSE_PROJECT_NAME", "DOCKER_GID", "JENKINS_AGENT_SSH_PRIVATE_KEY",
        "JENKINS_AGENT_HOST_KEY", "KEEP"}
print(" ".join(sorted(needed - have - skip)))
PY
)
if [ -n "$missing" ]; then
  echo "渲染产物缺少 compose 引用的变量：$missing" >&2
  exit 1
fi

# agent 的 SSH 密钥必须在 compose up 之前生成：jenkins 与 jenkins-agent 都 bind 了
# secrets/ 下的文件，文件不存在时 compose 直接报
# 「bind source path does not exist」，看不出是密钥没生成。
stage="generating agent ssh key"
bash /repo/scripts/40-gen-agent-key.sh >/dev/null

# JCasC 的 directEntry 引用 JENKINS_AGENT_SSH_PRIVATE_KEY，compose 里是裸变量，
# 必须在 compose 之前 export 才有值（写 .env 不行：既有「已有 .env 绝不修改」
# 的约定，dotenv 也不支持多行 PEM）。
if [ -r /repo/secrets/agent_ssh_key ]; then
  JENKINS_AGENT_SSH_PRIVATE_KEY="$(cat /repo/secrets/agent_ssh_key)"
  export JENKINS_AGENT_SSH_PRIVATE_KEY
fi

# agent 的 host key 公钥：JCasC 的 manuallyProvidedKeyVerificationStrategy 只认
# 「算法 + base64」两列，.pub 的第三列是注释，必须切掉再 export。
if [ -r /repo/secrets/agent_host_key.pub ]; then
  JENKINS_AGENT_HOST_KEY="$(awk 'NR==1{print $1" "$2}' /repo/secrets/agent_host_key.pub)"
  export JENKINS_AGENT_HOST_KEY
fi
if [ -z "${JENKINS_AGENT_HOST_KEY:-}" ]; then
  echo "agent_host_key.pub 缺失或为空：JCasC 的 host key 校验会启动失败" >&2
  exit 1
fi

# agent 容器里的 jenkins(1000) 要能读写 /var/run/docker.sock，必须把 socket 的 gid
# 补进容器（compose 的 group_add）。DinD 里这个 gid 和真机不同，所以同样要探测。
DOCKER_GID="${DOCKER_GID:-$(stat -c %g /var/run/docker.sock 2>/dev/null || echo 0)}"
export DOCKER_GID

# 域名相关产物必须在容器启动前就绪：
#   out/Caddyfile    caddy 挂载 /etc/caddy，缺文件会起不来
#   out/dex/config.yaml  dex 是 scratch 镜像，无法在启动期渲染
stage="rendering gateway config"
mkdir -p /repo/out
python3 /repo/services/router/render.py \
    --routes /repo/config/routes.yaml --out /repo/out/Caddyfile --admin ""
bash /repo/scripts/12-render-dex.sh --domain "$GATEWAY_DOMAIN" >/dev/null

printf '{"services":{}}\n' > "$M0_COMPOSE_OVERRIDE"
compose_ready=1
stage="preloading host images"
# save/load loses RepoDigests on classic Docker. Bind the verified host reference
# to its immutable config ID in a temporary override, never to an unverified tag.
config=$(compose config --format json)
while IFS=$'\t' read -r service image; do
    if [[ -S /host/docker.sock ]]; then
        id=$(docker -H unix:///host/docker.sock image inspect -f '{{.Id}}' "$image")
        if ! docker image inspect "$id" >/dev/null 2>&1; then
            echo "preload $service: $image"
            docker -H unix:///host/docker.sock save "$image" | docker load
        fi
        docker image inspect "$id" >/dev/null
    else
        id=$(docker image inspect -f '{{.Id}}' "$image") || {
            echo "missing $image; mount the host socket at /host/docker.sock" >&2
            exit 1
        }
    fi
    jq --arg service "$service" --arg id "$id" \
        '.services[$service] = {image: $id, pull_policy: "never"}' \
        "$M0_COMPOSE_OVERRIDE" > /tmp/m0-images.next
    mv /tmp/m0-images.next "$M0_COMPOSE_OVERRIDE"
done < <(jq -r '.name as $project | .services | to_entries[] |
    [.key, (.value.image // ($project + "-" + .key))] | @tsv' <<< "$config")

stage="starting inner stack"
compose up -d --no-build --pull never
stage="waiting for ten healthy services"
services=(dnsmasq jenkins jenkins-agent caddy router ldap ldapadmin dex oauth2-proxy homepage)
deadline=$((SECONDS + 300))
while :; do
    pending=()
    for service in "${services[@]}"; do
        id=$(compose ps -a -q "$service")
        [[ -n $id ]] || { echo "missing container: $service" >&2; exit 1; }
        health=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}missing-healthcheck{{end}}' "$id")
        if [[ $health != healthy ]]; then pending+=("$service=$health"); fi
    done
    if (( ${#pending[@]} == 0 )); then break; fi
    if (( SECONDS >= deadline )); then
        echo "health timeout (300s): ${pending[*]}" >&2
        exit 1
    fi
    echo "waiting: ${pending[*]}"
    sleep 5
done

# #46：Nexus 不是 compose 服务了，它由 Jenkins job `nexus-deploy` 部署。
# 测试栈里等价于「compose 起来之后跑一次 job」——所以直接跑脚本。
# 镜像同样按 config ID 钉死（tag 会漂，ID 不会），口径与上面的 compose 预载一致。
stage="deploying nexus (job equivalent)"
nexus_ref="$(awk -F '\t' '$1 == "nexus" {print $2 "@" $3}' /repo/tests/images.lock)"
if [[ -S /host/docker.sock ]]; then
    nexus_id=$(docker -H unix:///host/docker.sock image inspect -f '{{.Id}}' "$nexus_ref")
    if ! docker image inspect "$nexus_id" >/dev/null 2>&1; then
        echo "preload nexus: $nexus_ref"
        docker -H unix:///host/docker.sock save "$nexus_ref" | docker load
    fi
else
    nexus_id=$(docker image inspect -f '{{.Id}}' "$nexus_ref") || {
        echo "missing $nexus_ref; mount the host socket at /host/docker.sock" >&2
        exit 1
    }
fi
NEXUS_IMAGE="$nexus_id" \
NEXUS_ADMIN_ID="$(sed -n 's/^NEXUS_ADMIN_ID=//p' "$M0_ENV_FILE" | tail -1)" \
NEXUS_ADMIN_PASSWORD="$(sed -n 's/^NEXUS_ADMIN_PASSWORD=//p' "$M0_ENV_FILE" | tail -1)" \
    bash /repo/scripts/70-nexus-deploy.sh

# #117 三件套 + CE EULA + 匿名开启：测试栈等价于「部署机上手动跑 setup 脚本」。
# 全新 Nexus 不接受 EULA 时所有写路径 403（2026-11-14 CI 实测），匿名默认关闭
# 会让「未认证可拉」判据变 401。脚本幂等，213 上重跑同样安全。
# 走 router 容器的 python3（34_router_api.bats 同款先例）；凭据走 sh -c 位置
# 参数带进容器 —— compose exec 不透传宿主 shell 的环境变量（2026-11-14 CI
# 二轮实测：不传参则脚本报「NEXUS_ADMIN_PASSWORD 没有来源」）。
stage="provisioning nexus (eula/anonymous/repos)"
compose exec -T router sh -c 'cat > /tmp/nexus-setup-repos.py' \
    < /repo/scripts/72-nexus-setup-repos.py
compose exec -T router sh -c \
    'NEXUS_BASE_URL=http://nexus:8081 NEXUS_ADMIN_ID="$1" NEXUS_ADMIN_PASSWORD="$2" exec python3 /tmp/nexus-setup-repos.py' \
    nexus-setup \
    "$(sed -n 's/^NEXUS_ADMIN_ID=//p' "$M0_ENV_FILE" | tail -1)" \
    "$(sed -n 's/^NEXUS_ADMIN_PASSWORD=//p' "$M0_ENV_FILE" | tail -1)"

stage="bootstrapping isolated LDAP"
compose exec -T ldap sh -c 'LDAP_URI=ldap://localhost:389 bash /opt/orgflow-auth/bootstrap-ldif.sh'

# LDIF 里的 {SSHA} 是一份「谁都不知道真值」的哈希（公开仓库不能挂可用口令）。
# 目录建好之后改 LDIF 不会改已有条目，所以运行中的口令必须用 ldapmodify 显式设一遍，
# 否则测试拿 .env 的口令登录会一律 49/401 —— 这是 2026-11-11 三个用例红的根因。
stage="setting ldap user passwords"
COMPOSE="$(compose_cmd_string)" ENV_FILE="$M0_ENV_FILE" \
    bash /repo/scripts/11-ldap-set-passwords.sh

stage="running bats"
cd /repo
# 断言全部走域名 + SNI（--resolve 把域名钉到 127.0.0.1:8443），不依赖 hosts 文件
bats tests/bats/*.bats
