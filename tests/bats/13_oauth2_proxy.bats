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

    # #86:jenkins 摘网关后,其 403 是 Jenkins 自身对匿名用户的响应(自带登录),
    # 不再有 oauth2 跳转——受保护站点只剩 docs
    assert_gw jenkins / 403
    run gw_header jenkins / Location
    if [ "$status" -eq 0 ]; then
        ! grep -q "oauth2/start" <<< "$output"
    fi

    # 受保护站点(docs)未登录 → 302 萳本域 oauth2/start(#86 单域闭环,rd 带回原地址)
    assert_gw docs / 302
    run gw_header docs / Location
    [ "$status" -eq 0 ]
    assert_contains "$output" "https://docs.${GW_DOMAIN}/oauth2/start"
    assert_contains "$output" "rd="

    # auth 站点保留 /oauth2/start 入口(兼容),同样 302 到 dex
    assert_gw auth /oauth2/start 302
    run gw_header auth /oauth2/start Location
    [ "$status" -eq 0 ]
    assert_contains "$output" "https://dex.${GW_DOMAIN}/dex/auth"
    for value in client_id=jenkins redirect_uri= state=; do
        assert_contains "$output" "$value"
    done
}
