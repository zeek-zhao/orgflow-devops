#!/usr/bin/env bats
setup() {
    load 'helpers/common'
    setup_gw
}

@test "caddy: five domain sites, authentication, per-site 404 and Nexus API" {
    assert_gw auth /ping 200
    assert_gw jenkins / 302
    assert_gw dex /dex/keys 200
    assert_gw ldapadmin / 200
    assert_gw nexus / 200
    [ "$(grep -c reverse_proxy "$M0_REPO/out/Caddyfile")" -eq 5 ]
    [ "$(grep -c forward_auth "$M0_REPO/out/Caddyfile")" -eq 1 ]
    assert_gw nexus /service/rest/v1/status 200
}

@test "caddy: 站点地址全部是域名，旧路径入口已删除" {
    local file="$M0_REPO/out/Caddyfile"
    # 5 个站点块，每块都是 https://<sub>.<domain> { —— 地址里不带任何路径
    [ "$(grep -cE '^https://' "$file")" -eq 5 ]
    [ "$(grep -cE '^https://[a-z0-9-]+\.' "$file")" -eq 5 ]
    [ "$(grep -cE '^https://[^/{]+ \{' "$file")" -eq 5 ]
    # 反证：若还有路径式站点地址（https://host/jenkins），上面三条会先红
    ! grep -qE '^https://[^ ]+/[a-z]' "$file"
    # 内部 CA：不向公网申请证书
    grep -qx $'\tlocal_certs' "$file"
    for sub in jenkins nexus ldapadmin dex auth; do
        grep -qx "https://${sub}.${GW_DOMAIN} {" "$file"
    done
}

@test "caddy: HTTP 端口只做跳转，未知域名返回 404" {
    # 已知域名：80 → 443 跳转
    run http_host_header "jenkins.${GW_DOMAIN}" / Location
    [ "$status" -eq 0 ]
    assert_contains "$output" "https://jenkins.${GW_DOMAIN}/"
    # 旧入口 http://localhost:8080/jenkins 已不存在：没有站点匹配 Host 就 404
    run http_host_code localhost /jenkins
    [ "$status" -eq 0 ]
    [ "$output" = 404 ]
}
