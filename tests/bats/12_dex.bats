#!/usr/bin/env bats
setup() {
    load 'helpers/common'
    setup_gw
}

@test "dex: discovery, signing keys and health endpoint on the dex subdomain" {
    # dex 的端点都挂在 issuer 路径 /dex 下（域名路由不剥前缀）
    assert_gw dex /dex/.well-known/openid-configuration 200
    run gw_body dex /dex/.well-known/openid-configuration
    [ "$status" -eq 0 ]
    # run 会把 $output 覆盖成命令结果，所以先留一份原始响应体
    local discovery="$output"
    # issuer 必须是浏览器可达的绝对域名地址（模板渲染生效的直接证据）
    run jq -r '.issuer' <<< "$discovery"
    [ "$output" = "https://dex.${GW_DOMAIN}/dex" ]
    run jq -e '(.jwks_uri | type == "string" and length > 0) and
        (.authorization_endpoint | type == "string" and length > 0) and
        (.token_endpoint | type == "string" and length > 0)' <<< "$discovery"
    [ "$status" -eq 0 ]
    assert_gw dex /dex/keys 200
    run gw_body dex /dex/keys
    [ "$status" -eq 0 ]
    jq -e '.keys | type == "array" and length > 0' <<< "$output"
    assert_gw dex /dex/healthz 200
}
