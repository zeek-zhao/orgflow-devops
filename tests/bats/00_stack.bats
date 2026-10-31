#!/usr/bin/env bats
setup() {
    load 'helpers/common'
    setup_gw
}

@test "stack: locked images, ten services and Ubuntu build bases" {
    local file="$M0_REPO/docker-compose.yml" image name ref digest expected
    # jenkins 改成自建后不再有 image: 行（走 build:），所以从 8 降到 7。
    # 剩下 7 个都是上游/mirror 镜像，必须逐条对得上 images.lock。
    [ "$(grep -cE '^[[:space:]]+image:' "$file")" -eq 7 ]
    [ "$(grep -cE '^[[:space:]]+image:.*@sha256:' "$file")" -eq 7 ]
    while read -r image; do
        expected=
        while IFS=$'\t' read -r name ref digest; do
            [[ $name == \#* || -z $name ]] && continue
            if [[ ${image%@*} == "$ref" ]]; then expected="$ref@$digest"; fi
        done < "$M0_REPO/tests/images.lock"
        [ -n "$expected" ]
        [ "$image" = "$expected" ]
    done < <(awk '$1 == "image:" {print $2}' "$file")
    run compose_cmd config --services
    [ "$status" -eq 0 ]
    [ "$(printf '%s\n' "$output" | wc -l)" -eq 10 ]
    for name in dnsmasq jenkins caddy router ldap ldapadmin dex oauth2-proxy nexus homepage; do
        printf '%s\n' "$output" | grep -qx "$name"
    done
    expected=$(awk -F '\t' '$1 == "ubuntu" {print $2 "@" $3}' "$M0_REPO/tests/images.lock")
    for file in services/dnsmasq/Dockerfile services/router/Dockerfile \
                tools/jjb/Dockerfile tests/harness/Dockerfile; do
        [ "$(grep -c '^FROM ' "$M0_REPO/$file")" -eq 1 ]
        grep -Fx "FROM $expected" "$M0_REPO/$file"
        grep -Eq '^FROM ubuntu:24\.04@sha256:[a-f0-9]{64}$' "$M0_REPO/$file"
    done
    # jenkins 底座不是 ubuntu，进不了上面的 lock 循环，单独钉死：
    # 213 拉不到 Docker Hub，镜像只在 runner 上构建，底座漂了就等于 213 上行为漂了。
    [ "$(grep -c '^FROM ' "$M0_REPO/tools/jenkins/Dockerfile")" -eq 1 ]
    grep -Eq '^FROM jenkins/jenkins:lts-jdk21@sha256:[a-f0-9]{64}$' "$M0_REPO/tools/jenkins/Dockerfile"
}

@test "stack: every service on the orgflow network has a fixed IPv4" {
    local file="$M0_REPO/docker-compose.yml"
    # jjb 用 host 网络（要访问宿主上的网关入口），其余 10 个服务全部固定 IP
    [ "$(grep -cE '^[[:space:]]+ipv4_address:' "$file")" -eq 10 ]
    [ "$(grep -cE '^[[:space:]]+ipv4_address: 172\.31\.0\.' "$file")" -eq 10 ]
    # 固定 IP 必须唯一，否则 compose 起不来（这里先静态证伪）
    [ "$(grep -E '^[[:space:]]+ipv4_address:' "$file" | sort -u | wc -l)" -eq 10 ]
    grep -q 'subnet: 172.31.0.0/24' "$file"
}
