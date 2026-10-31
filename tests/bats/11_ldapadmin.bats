#!/usr/bin/env bats
setup() {
    load 'helpers/common'
    setup_gw
}

@test "ldapadmin: public page is reachable on its own subdomain" {
    assert_gw ldapadmin / 200
    run gw_body ldapadmin /
    [ "$status" -eq 0 ]
    grep -qi phpLDAPadmin <<< "$output"
}
