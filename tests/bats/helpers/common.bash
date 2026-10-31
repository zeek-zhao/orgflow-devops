# bats 公共助手 —— 域名路由模型（M0 ADR-13）
#
# 断言一律走「域名 + SNI」，不依赖 hosts 文件：
#   curl --resolve <sub>.<domain>:<port>:127.0.0.1 https://<sub>.<domain>/...
# 这样测的就是 Caddy 的站点匹配（Host/SNI），而不是某个 IP:端口。
#
# 环境变量（tests/harness/entrypoint.sh 里设置）：
#   GW_DOMAIN      网关域名后缀，默认 org-devops.com
#   GW_HOST        网关所在地址，默认 127.0.0.1
#   GW_HTTPS_PORT  网关 HTTPS 映射端口，默认 8443
#   GW_HTTP_PORT   网关 HTTP  映射端口，默认 8080

setup_gw() {
    GW_DOMAIN=${GW_DOMAIN:-org-devops.com}
    GW_HOST=${GW_HOST:-127.0.0.1}
    GW_HTTPS_PORT=${GW_HTTPS_PORT:-8443}
    GW_HTTP_PORT=${GW_HTTP_PORT:-8080}
    # 认证网关子域：与 config/routes.yaml 里 name: auth 那条路由的 subdomain 一致
    GW_AUTH=${GW_AUTH:-auth}
    M0_REPO=${M0_REPO:-/repo}
    M0_ENV_FILE=${M0_ENV_FILE:-$M0_REPO/.env}
}

# ---------------------------------------------------------------- HTTP 断言

# gw_curl <子域> <路径> [curl 额外参数...]
# URL 里必须显式带端口：--resolve 是按 host:port 匹配的，
# 只写 https://host/ 的话 curl 按 443 去连，映射对不上就去查 DNS 了。
gw_curl() {
    local sub=$1 path=$2
    shift 2
    curl -sSk --connect-timeout 5 --max-time 20 \
        --resolve "${sub}.${GW_DOMAIN}:${GW_HTTPS_PORT}:${GW_HOST}" \
        "https://${sub}.${GW_DOMAIN}:${GW_HTTPS_PORT}${path}" "$@"
}

gw_code() {
    gw_curl "$1" "$2" -o /dev/null -w '%{http_code}'
}

gw_header() {
    local headers
    headers=$(gw_curl "$1" "$2" -D - -o /dev/null) || return
    awk -v name="$3" 'tolower($1) == tolower(name ":") {
        sub(/^[^:]+:[ \t]*/, ""); sub(/\r$/, ""); print
    }' <<< "$headers"
}

gw_body() {
    gw_curl "$1" "$2" -f
}

assert_gw() {
    local actual
    actual=$(gw_code "$1" "$2") || return
    if [[ $actual != "$3" ]]; then
        echo "https://$1.$GW_DOMAIN:$GW_HTTPS_PORT$2: expected HTTP $3, got $actual" >&2
        return 1
    fi
}

# gw_wait <子域> <路径> <期望状态码> <超时秒>
gw_wait() {
    local sub=$1 path=$2 expected=$3 deadline=$((SECONDS + $4)) actual
    while (( SECONDS <= deadline )); do
        if actual=$(gw_code "$sub" "$path") && [[ $actual == "$expected" ]]; then
            return 0
        fi
        sleep 1
    done
    echo "https://$sub.$GW_DOMAIN:$GW_HTTPS_PORT$path: expected $expected, last status ${actual:-connection-failed}" >&2
    return 1
}

# 明文 HTTP 端口：用 Host 头指定域名，验证 80 → 443 跳转与未知域名 404
http_host_code() {
    curl -sS --connect-timeout 5 --max-time 20 -o /dev/null -w '%{http_code}' \
        -H "Host: $1" "http://${GW_HOST}:${GW_HTTP_PORT}${2}"
}

http_host_header() {
    local headers
    headers=$(curl -sS --connect-timeout 5 --max-time 20 -D - -o /dev/null \
        -H "Host: $1" "http://${GW_HOST}:${GW_HTTP_PORT}${2}") || return
    awk -v name="$3" 'tolower($1) == tolower(name ":") {
        sub(/^[^:]+:[ \t]*/, ""); sub(/\r$/, ""); print
    }' <<< "$headers"
}

# ---------------------------------------------------------------- 容器断言

compose_cmd() {
    local args=(-f "$M0_REPO/docker-compose.yml")
    if [[ -n ${M0_COMPOSE_EXTRA:-} ]]; then args+=(-f "$M0_COMPOSE_EXTRA"); fi
    if [[ -n ${M0_COMPOSE_OVERRIDE:-} ]]; then args+=(-f "$M0_COMPOSE_OVERRIDE"); fi
    docker compose "${args[@]}" --env-file "$M0_ENV_FILE" --project-directory "$M0_REPO" "$@"
}

compose_exec() {
    compose_cmd exec -T "$@"
}

assert_contains() {
    if [[ $1 != *"$2"* ]]; then
        printf 'expected %q to contain %q\n' "$1" "$2" >&2
        return 1
    fi
}

assert_healthy() {
    local id
    id=$(compose_cmd ps -q "$1") || return
    [ "$(docker inspect -f '{{.State.Health.Status}}' "$id")" = healthy ]
}

# 固定 IP 是排查的锚点：容器 IP 变了，架构图上的定位就全错。
assert_fixed_ip() {
    local id actual
    id=$(compose_cmd ps -q "$1") || return
    actual=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$id")
    if [[ $actual != "$2" ]]; then
        echo "$1: expected fixed IP $2, got ${actual:-none}" >&2
        return 1
    fi
}

# ------------------------------------------------- 非 compose 容器的断言（#46）
#
# Nexus 不再由 compose 管理，它是 job `nexus-deploy` 用 docker run 创建的。
# `compose ps -q nexus` 对它返回空，所以上面那组按服务名查的断言全都不适用，
# 这里按容器名直接查。

docker_exec() { docker exec -i "$@"; }

assert_container_healthy() {
    local status
    status=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}no-healthcheck{{end}}' "$1" 2>/dev/null) || return
    if [[ $status != healthy ]]; then
        echo "$1: expected healthy, got ${status:-missing}" >&2
        return 1
    fi
}

assert_container_ip() {
    local actual
    actual=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$1" 2>/dev/null) || return
    if [[ $actual != "$2" ]]; then
        echo "$1: expected fixed IP $2, got ${actual:-none}" >&2
        return 1
    fi
}

assert_resolves_in_container() {
    local container=$1 name=$2 expected=$3 out
    # 不在容器里跑 `sh -c 'if command -v ...'`：nexus 的底座镜像精简得厉害，
    # 一旦缺 shell 或内建命令，整个 exec 会以奇怪的退出码失败，
    # 报出来是「解析失败」，实际是「探测脚本本身跑不起来」。
    # 改成从宿主侧逐个试，哪个工具不存在就让 docker exec 返回 127，`|| true` 吞掉。
    out=$(docker exec "$container" getent hosts "$name" 2>/dev/null || true)
    [[ -n $out ]] || out=$(docker exec "$container" nslookup "$name" 2>/dev/null || true)
    [[ -n $out ]] || out=$(docker exec "$container" dig +short "$name" 2>/dev/null || true)
    # 三个工具都没有时退回 curl：打网关的 80 端口（Caddy 会回 308，连接是通的），
    # 用 %{remote_ip} 证明名字被解析到了哪个地址。
    # 不要打一个没人监听的端口 —— curl 的 remote_ip 只在连接建立后才填，
    # 连接被拒时是空串，会把「解析失败」和「端口没开」混成同一个现象。
    [[ -n $out ]] || out=$(docker exec "$container" curl -s -o /dev/null -w '%{remote_ip}' \
        --max-time 3 "http://$name/" 2>/dev/null || true)
    if [[ $out != *"$expected"* ]]; then
        echo "$container: cannot resolve $name to $expected; got: ${out:-<empty>}" >&2
        return 1
    fi
}

# 容器内域名解析：验证 dnsmasq 供货，且服务确实用了它当 resolver。
# 容器基础镜像不同（alpine 无 getent、debian 有），按可用工具降级；
# 断言只看"输出里出现期望 IP"，不依赖某个工具的固定输出格式。
assert_resolves_in() {
    local service=$1 name=$2 expected=$3 out
    out=$(compose_exec "$service" sh -c "
        if command -v getent >/dev/null 2>&1; then getent hosts '$name'
        elif command -v nslookup >/dev/null 2>&1; then nslookup '$name'
        elif command -v dig >/dev/null 2>&1; then dig +short '$name'
        else echo no-resolver-tool; fi") || return
    if [[ $out != *"$expected"* ]]; then
        echo "$service: cannot resolve $name to $expected; got: ${out:-<empty>}" >&2
        return 1
    fi
}
