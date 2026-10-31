#!/usr/bin/env bats
setup() {
    load 'helpers/common'
    setup_gw
}

@test "stack: locked images, nine services and Ubuntu build bases" {
    local file="$M0_REPO/docker-compose.yml" image name ref digest expected
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
    [ "$(printf '%s\n' "$output" | wc -l)" -eq 9 ]
    for name in dnsmasq jenkins caddy router ldap ldapadmin dex oauth2-proxy nexus; do
        printf '%s\n' "$output" | grep -qx "$name"
    done
    expected=$(awk -F '\t' '$1 == "ubuntu" {print $2 "@" $3}' "$M0_REPO/tests/images.lock")
    for file in services/dnsmasq/Dockerfile services/router/Dockerfile \
                tools/jjb/Dockerfile tests/harness/Dockerfile; do
        [ "$(grep -c '^FROM ' "$M0_REPO/$file")" -eq 1 ]
        grep -Fx "FROM $expected" "$M0_REPO/$file"
        grep -Eq '^FROM ubuntu:24\.04@sha256:[a-f0-9]{64}$' "$M0_REPO/$file"
    done
}

@test "stack: every service on the orgflow network has a fixed IPv4" {
    local file="$M0_REPO/docker-compose.yml"
    # jjb 用 host 网络（要访问宿主上的网关入口），其余 9 个服务全部固定 IP
    [ "$(grep -cE '^[[:space:]]+ipv4_address:' "$file")" -eq 9 ]
    [ "$(grep -cE '^[[:space:]]+ipv4_address: 172\.31\.0\.' "$file")" -eq 9 ]
    # 固定 IP 必须唯一，否则 compose 起不来（这里先静态证伪）
    [ "$(grep -E '^[[:space:]]+ipv4_address:' "$file" | sort -u | wc -l)" -eq 9 ]
    grep -q 'subnet: 172.31.0.0/24' "$file"
}
