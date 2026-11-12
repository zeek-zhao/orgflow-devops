#!/usr/bin/env bats
setup() {
    load 'helpers/common'
    setup_gw
}

@test "caddy: ten domain sites, authentication, per-site 404 and Nexus API (#117 #62)" {
    assert_gw auth /ping 200
    assert_gw jenkins / 403
    assert_gw dex /dex/keys 200
    assert_gw ldapadmin / 200
    assert_gw nexus / 200
    local expected_site_count actual_proxy_count
    expected_site_count=$(grep -cE '^[[:space:]]*subdomain:' "$M0_REPO/config/routes.yaml")
    actual_proxy_count=$(grep -cE '^[[:space:]]*reverse_proxy ' "$M0_REPO/out/Caddyfile")
    [ "$actual_proxy_count" -eq "$expected_site_count" ] # #117: docker/pypi；#62: ca；#86: docs/auth
    [ "$(grep -c forward_auth "$M0_REPO/out/Caddyfile")" -eq 1 ] # #86: 仅 docs 站点需要网关认证
    assert_gw nexus /service/rest/v1/status 200
}

@test "caddy: 站点地址全部是域名，旧路径入口已删除 (#117 #62)" {
    local file="$M0_REPO/out/Caddyfile"
    # 路由真源当前有 10 个子域；每个都必须生成独立的 https://<sub>.<domain> 站点。#117 #62
    local expected_site_count
    expected_site_count=$(grep -cE '^[[:space:]]*subdomain:' "$M0_REPO/config/routes.yaml") # #117: docker/pypi；#62: ca；#86: docs/auth
    [ "$(grep -cE '^https://' "$file")" -eq "$expected_site_count" ]
    [ "$(grep -cE '^https://[a-z0-9-]+\.' "$file")" -eq "$expected_site_count" ]
    [ "$(grep -cE '^https://[^/{]+ \{' "$file")" -eq "$expected_site_count" ]
    # 反证：若还有路径式站点地址（https://host/jenkins），上面三条会先红
    ! grep -qE '^https://[^ ]+/[a-z]' "$file"
    # 内部 CA：不向公网申请证书
    grep -qx $'\tlocal_certs' "$file"
    local sub
    for sub in jenkins nexus docker pypi ldapadmin dex auth home ca docs; do # #117 #62 #86
        grep -qx "https://${sub}.${GW_DOMAIN} {" "$file"
    done
}

@test "caddy: HTTP 端口只做跳转，未知域名没有站点承接" {
    # 已知域名：80 → 443 跳转，且路径原样保留（路径式站点确实没了）
    run http_host_header "jenkins.${GW_DOMAIN}" /jenkins Location
    [ "$status" -eq 0 ]
    assert_contains "$output" "https://jenkins.${GW_DOMAIN}/jenkins"
    # 未知域名没有站点承接：连证书都签不出来，握手直接失败
    run curl -sS --max-time 20 -o /dev/null -w '%{http_code}' \
        --resolve "unknown.${GW_DOMAIN}:${GW_HTTPS_PORT}:${GW_HOST}" \
        "https://unknown.${GW_DOMAIN}:${GW_HTTPS_PORT}/jenkins"
    [ "$status" -ne 0 ]
}
