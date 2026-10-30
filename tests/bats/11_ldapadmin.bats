#!/usr/bin/env bats
setup() {
    load 'helpers/common'
    setup_http
}

@test "ldapadmin: public page is reachable" {
    assert_http /ldapadmin/ 200
    run http_body /ldapadmin/
    [ "$status" -eq 0 ]
    grep -qi phpLDAPadmin <<< "$output"
}
