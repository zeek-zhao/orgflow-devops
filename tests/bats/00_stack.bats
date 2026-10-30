#!/usr/bin/env bats
setup() {
    load 'helpers/common'
    setup_http
}

@test "stack: locked images, eight services and Ubuntu build bases" {
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
    [ "$(printf '%s\n' "$output" | wc -l)" -eq 8 ]
    for name in jenkins caddy router ldap ldapadmin dex oauth2-proxy nexus; do
        printf '%s\n' "$output" | grep -qx "$name"
    done
    expected=$(awk -F '\t' '$1 == "ubuntu" {print $2 "@" $3}' "$M0_REPO/tests/images.lock")
    for file in services/router/Dockerfile tools/jjb/Dockerfile tests/harness/Dockerfile; do
        [ "$(grep -c '^FROM ' "$M0_REPO/$file")" -eq 1 ]
        grep -Fx "FROM $expected" "$M0_REPO/$file"
        grep -Eq '^FROM ubuntu:24\.04@sha256:[a-f0-9]{64}$' "$M0_REPO/$file"
    done
}
