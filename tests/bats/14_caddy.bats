#!/usr/bin/env bats
setup() {
    load 'helpers/common'
    setup_http
}

@test "caddy: five routes, authentication, 404 fallback and Nexus API" {
    assert_http /auth/ping 200
    assert_http /jenkins 302
    assert_http /dex/keys 200
    assert_http /ldapadmin/ 200
    assert_http /nexus/ 200
    assert_http /nope 404
    [ "$(grep -c reverse_proxy "$M0_REPO/out/Caddyfile")" -eq 5 ]
    [ "$(grep -c forward_auth "$M0_REPO/out/Caddyfile")" -eq 1 ]
    assert_http /nexus/service/rest/v1/status 200
}
