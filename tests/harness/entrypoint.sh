#!/usr/bin/env bash
set -Eeuo pipefail
set +x
export DOCKER_HOST=unix:///var/run/docker.sock
unset DOCKER_CONTEXT
export GATEWAY_PORT=8080
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
        compose logs --no-color --tail=50 >&2 || echo "compose logs failed" >&2
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
if [[ ! -f $M0_ENV_FILE ]]; then
    M0_ENV_FILE=/tmp/m0.env
    cp /repo/.env.example "$M0_ENV_FILE"
    for key in LDAP_ADMIN_PASSWORD OAUTH2_CLIENT_SECRET OAUTH2_COOKIE_SECRET JENKINS_ADMIN_PASSWORD; do
        secret=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
        sed -i "s/^${key}=.*/${key}=${secret}/" "$M0_ENV_FILE"
    done
fi
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
stage="waiting for eight healthy services"
services=(jenkins caddy router ldap ldapadmin dex oauth2-proxy nexus)
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
M0_BASE_URL=http://127.0.0.1:8080 bats tests/bats/*.bats
