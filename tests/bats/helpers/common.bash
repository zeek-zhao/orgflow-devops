setup_http() {
    BASE_URL=${M0_BASE_URL:-http://127.0.0.1:8080}
    M0_REPO=${M0_REPO:-/repo}
    M0_ENV_FILE=${M0_ENV_FILE:-$M0_REPO/.env}
}

http_code() {
    curl -sS --connect-timeout 5 --max-time 20 -o /dev/null -w '%{http_code}' "$BASE_URL$1"
}

http_header() {
    local headers
    headers=$(curl -sS --connect-timeout 5 --max-time 20 -D - -o /dev/null "$BASE_URL$1") || return
    awk -v name="$2" 'tolower($1) == tolower(name ":") {
        sub(/^[^:]+:[ \t]*/, ""); sub(/\r$/, ""); print
    }' <<< "$headers"
}

http_body() {
    curl -fsS --connect-timeout 5 --max-time 20 "$BASE_URL$1"
}

compose_cmd() {
    local args=(-f "$M0_REPO/docker-compose.yml")
    if [[ -n ${M0_COMPOSE_EXTRA:-} ]]; then args+=(-f "$M0_COMPOSE_EXTRA"); fi
    if [[ -n ${M0_COMPOSE_OVERRIDE:-} ]]; then args+=(-f "$M0_COMPOSE_OVERRIDE"); fi
    docker compose "${args[@]}" --env-file "$M0_ENV_FILE" --project-directory "$M0_REPO" "$@"
}

compose_exec() {
    compose_cmd exec -T "$@"
}

wait_http() {
    local path=$1 expected=$2 deadline=$((SECONDS + $3)) actual
    while (( SECONDS <= deadline )); do
        if actual=$(http_code "$path") && [[ $actual == "$expected" ]]; then return 0; fi
        sleep 1
    done
    echo "$path: expected $expected, last status ${actual:-connection-failed}" >&2
    return 1
}

assert_contains() {
    if [[ $1 != *"$2"* ]]; then
        printf 'expected %q to contain %q\n' "$1" "$2" >&2
        return 1
    fi
}

assert_http() {
    local actual
    actual=$(http_code "$1") || return
    if [[ $actual != "$2" ]]; then
        echo "$1: expected HTTP $2, got $actual" >&2
        return 1
    fi
}

assert_healthy() {
    local id
    id=$(compose_cmd ps -q "$1") || return
    [ "$(docker inspect -f '{{.State.Health.Status}}' "$id")" = healthy ]
}
