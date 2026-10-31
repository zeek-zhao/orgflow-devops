#!/usr/bin/env bats
setup() {
    load 'helpers/common'
    setup_gw
}

# 镜像公开是「拉得到」这件事的前提，不是一句声明：
# 只要有人把某个包改回 private，213 上（Docker Hub 不可达）就会拉不动，
# 而症状是「构建莫名其妙失败」，很难一眼看出是权限问题。
#
# 这里用完全匿名的路径取证：先拿不带任何凭据的 pull token，
# 再用它 HEAD manifest。private 包的 token 会拿到 200 但没有 pull 权限，
# 于是 manifest 返回 401 —— 正好是我们要拦住的情况。

GHCR="ghcr.io/v2/zeek-zhao/orgflow-devops"
ACCEPT="application/vnd.oci.image.index.v1+json,application/vnd.oci.image.manifest.v1+json,application/vnd.docker.distribution.manifest.list.v2+json,application/vnd.docker.distribution.manifest.v2+json"

# 匿名 token：不传任何 Authorization，模拟一台没有任何凭据的机器
anon_token() {
    curl -sS --max-time 20 \
        "https://ghcr.io/token?scope=repository:zeek-zhao/orgflow-devops/$1:pull&service=ghcr.io" \
        | jq -r '.token // empty'
}

manifest_code() {
    local repo=$1 tag=$2 token
    token=$(anon_token "$repo")
    if [[ -z $token ]]; then
        echo "no-token"
        return
    fi
    curl -sS --max-time 20 -o /dev/null -w '%{http_code}' -I \
        -H "Authorization: Bearer $token" -H "Accept: $ACCEPT" \
        "$GHCR/$repo/manifests/$tag"
}

@test "public: 12 个 GHCR 包都能匿名取到 manifest（无需登录）" {
    local entry repo tag code
    for entry in \
        "router:24.04-v1" "jjb:24.04-v1" "m0-test:24.04-v1" "dnsmasq:24.04-v1" \
        "mirror-caddy:2" "mirror-jenkins:lts-jdk17" "mirror-openldap:1.5.0" \
        "mirror-phpldapadmin:0.9.0" "mirror-dex:v2.41.1" \
        "mirror-oauth2-proxy:v7.6.0" "mirror-nexus:3.92.2" "mirror-ubuntu:24.04"
    do
        repo=${entry%%:*}
        tag=${entry#*:}
        code=$(manifest_code "$repo" "$tag")
        if [[ $code != 200 ]]; then
            echo "$repo:$tag -> HTTP $code（包可能被改回 private，或 tag 已不存在）" >&2
            return 1
        fi
    done
}

@test "public: 反证——不存在的包必须拿不到 200（否则上一条是假绿）" {
    # 如果这条也能拿到 200，说明探针根本没在判断可见性，
    # 上面 12 个包的「全绿」就没有意义。
    local code
    code=$(manifest_code "does-not-exist-$$" "latest")
    [[ $code != 200 ]]
}
