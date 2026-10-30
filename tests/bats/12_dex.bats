#!/usr/bin/env bats
setup() {
    load 'helpers/common'
    setup_http
}

@test "dex: discovery, signing keys and health endpoint" {
    assert_http /dex/.well-known/openid-configuration 200
    run http_body /dex/.well-known/openid-configuration
    [ "$status" -eq 0 ]
    jq -e '(.issuer | endswith("/dex")) and
        (.jwks_uri | type == "string" and length > 0) and
        (.authorization_endpoint | type == "string" and length > 0) and
        (.token_endpoint | type == "string" and length > 0)' <<< "$output"
    assert_http /dex/keys 200
    run http_body /dex/keys
    [ "$status" -eq 0 ]
    jq -e '.keys | type == "array" and length > 0' <<< "$output"
    assert_http /dex/healthz 200
}
