#!/usr/bin/env bats
setup() {
    load 'helpers/common'
    setup_gw
}

@test "oauth2-proxy: ping and unauthenticated OIDC redirects across domains" {
    assert_gw auth /ping 200
    run gw_body auth /ping
    [ "$status" -eq 0 ]
    assert_contains "$output" OK

    # 受保护站点未登录 → 跳到认证域名（绝对地址，不是相对路径）
    assert_gw jenkins / 302
    run gw_header jenkins / Location
    [ "$status" -eq 0 ]
    assert_contains "$output" "https://${GW_AUTH}.${GW_DOMAIN}/oauth2/start"
    # rd 带完整原始 URL，登录后能回到用户本来要去的页面
    assert_contains "$output" "jenkins.${GW_DOMAIN}"

    # 认证网关自身再跳 dex（跨域名的第二个跳转）
    assert_gw auth /oauth2/start 302
    run gw_header auth /oauth2/start Location
    [ "$status" -eq 0 ]
    assert_contains "$output" "https://dex.${GW_DOMAIN}/dex/auth"
    for value in client_id=jenkins redirect_uri= state=; do
        assert_contains "$output" "$value"
    done
}
