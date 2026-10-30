#!/usr/bin/env bats
setup() {
    load 'helpers/common'
    setup_http
}

@test "nexus: public UI, empty-body status API and healthy container" {
    assert_http /nexus/ 200
    assert_http /nexus/service/rest/v1/status 200
    assert_healthy nexus
}
