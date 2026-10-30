#!/usr/bin/env bats
setup() {
    load 'helpers/common'
    setup_http
}

@test "oauth2-proxy: ping and unauthenticated OIDC redirects" {
    assert_http /auth/ping 200
    run http_body /auth/ping
    [ "$status" -eq 0 ]
    assert_contains "$output" OK
    assert_http /jenkins 302
    run http_header /jenkins Location
    [ "$status" -eq 0 ]
    assert_contains "$output" /auth/oauth2/start
    assert_http /auth/oauth2/start 302
    run http_header /auth/oauth2/start Location
    [ "$status" -eq 0 ]
    for value in /dex/auth client_id=jenkins redirect_uri= state=; do
        assert_contains "$output" "$value"
    done
}
