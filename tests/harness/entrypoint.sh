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
    if [[ ${KEEP:-0} == 1 ]]; then
        echo "KEEP=1: preserving inner containers and m0-dind data; harness stays available for docker exec."
        echo "Stop the harness explicitly after inspection; rerun without KEEP to clean the inner stack."
        trap 'kill "$daemon_pid"; wait "$daemon_pid"; exit "$status"' TERM INT
        wait "$daemon_pid"
    else
        if (( compose_ready )); then
            compose down -v || { echo "inner compose cleanup failed" >&2; status=1; }
        fi
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
# 始终用临时副本：下面要追加域名/端口覆盖，绝不能改仓库里的 .env
source_env=$M0_ENV_FILE
M0_ENV_FILE=/tmp/m0.env
if [[ -f $source_env ]]; then
    cp "$source_env" "$M0_ENV_FILE"
else
    cp /repo/.env.example "$M0_ENV_FILE"
    for key in LDAP_ADMIN_PASSWORD OAUTH2_CLIENT_SECRET OAUTH2_COOKIE_SECRET JENKINS_ADMIN_PASSWORD; do
        secret=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
        sed -i "s/^${key}=.*/${key}=${secret}/" "$M0_ENV_FILE"
    done
fi
# 追加覆盖（dotenv 后者生效）：测试栈固定域名与端口，不受调用方 .env 影响
cat >> "$M0_ENV_FILE" <<EOF
GATEWAY_DOMAIN=$GATEWAY_DOMAIN
GATEWAY_HTTP_PORT=$GW_HTTP_PORT
GATEWAY_HTTPS_PORT=$GW_HTTPS_PORT
EOF

# agent 的 SSH 密钥必须在 compose up 之前生成：jenkins 与 jenkins-agent 都 bind 了
# secrets/ 下的文件，文件不存在时 compose 直接报
# 「bind source path does not exist」，看不出是密钥没生成。
stage="generating agent ssh key"
bash /repo/scripts/gen-agent-key.sh >/dev/null

# JCasC 的 directEntry 引用 JENKINS_AGENT_SSH_PRIVATE_KEY，compose 里是裸变量，
# 必须在 compose 之前 export 才有值（写 .env 不行：既有「已有 .env 绝不修改」
# 的约定，dotenv 也不支持多行 PEM）。
if [ -r /repo/secrets/agent_ssh_key ]; then
  JENKINS_AGENT_SSH_PRIVATE_KEY="$(cat /repo/secrets/agent_ssh_key)"
  export JENKINS_AGENT_SSH_PRIVATE_KEY
fi

# 域名相关产物必须在容器启动前就绪：
#   out/Caddyfile    caddy 挂载 /etc/caddy，缺文件会起不来
#   out/dex/config.yaml  dex 是 scratch 镜像，无法在启动期渲染
stage="rendering gateway config"
mkdir -p /repo/out
python3 /repo/services/router/render.py \
    --routes /repo/config/routes.yaml --out /repo/out/Caddyfile --admin ""
bash /repo/scripts/render-dex.sh --domain "$GATEWAY_DOMAIN" >/dev/null

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
stage="waiting for eleven healthy services"
services=(dnsmasq jenkins jenkins-agent caddy router ldap ldapadmin dex oauth2-proxy nexus homepage)
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

stage="bootstrapping isolated LDAP"
compose exec -T ldap sh -c 'LDAP_URI=ldap://localhost:389 bash /opt/orgflow-auth/bootstrap-ldif.sh'
stage="running bats"
cd /repo
# 断言全部走域名 + SNI（--resolve 把域名钉到 127.0.0.1:8443），不依赖 hosts 文件
bats tests/bats/*.bats
