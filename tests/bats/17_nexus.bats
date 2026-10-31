#!/usr/bin/env bats
setup() {
    load 'helpers/common'
    setup_gw
}

@test "nexus: public UI, empty-body status API and healthy container" {
    assert_gw nexus / 200
    assert_gw nexus /service/rest/v1/status 200
    assert_healthy nexus
    assert_fixed_ip nexus 172.31.0.21
}
