#!/usr/bin/env bats
# #86 网关权限收口:oauth2-proxy 只守文档站,按 docs-users 组授权。
# 硬判据:非组成员完成 OIDC 后访问受保护路由必须被拒;组成员放行。
setup() {
    load 'helpers/common'
    setup_gw
}

@test "gateway acl: forward_auth 只剩文档站 1 处,jenkins/ldapadmin 已摘" {
    [ "$(grep -c forward_auth "$M0_REPO/out/Caddyfile")" -eq 1 ]
    grep -q "https://docs.${GW_DOMAIN} {" "$M0_REPO/out/Caddyfile"
    ! grep -q "https://jenkins.${GW_DOMAIN} {" <<< "$(grep -B1 -A6 forward_auth "$M0_REPO/out/Caddyfile")"
}

@test "gateway acl: oauth2-proxy 参数收紧(trusted-proxy-ip/allowed-group/单域 cookie)" {
    run compose_cmd config
    [ "$status" -eq 0 ]
    [ "$(grep -c trusted-proxy-ip <<< "$output")" -ge 1 ]
    grep -q "allowed-group=docs-users" <<< "$output"
    grep -q "cookie-domain=docs.${GW_DOMAIN}" <<< "$output"
    ! grep -q "email-domain=\*" <<< "$output"
}

@test "gateway acl: 组成员(svc-platform-dev)完成 OIDC 后访问文档站放行" {
    run python3 "$M0_REPO/tests/bats/helpers/oidc_flow.py" \
        "docs.${GW_DOMAIN}" "${GW_HTTPS_PORT}" svc-platform-dev '123456'
    echo "flow: $output" >&2
    [ "$status" -eq 0 ]
    assert_contains "$output" "200"
}

@test "gateway acl: 非组成员(svc-jira-dev)完成 OIDC 后必须被拒" {
    run python3 "$M0_REPO/tests/bats/helpers/oidc_flow.py" \
        "docs.${GW_DOMAIN}" "${GW_HTTPS_PORT}" svc-jira-dev '123456'
    echo "flow: $output" >&2
    # oauth2-proxy 在 allowed-group 不匹配时拒绝:403(登录页报 Access Denied)
    assert_contains "$output" "403"
}
