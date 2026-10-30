#!/usr/bin/env bats
setup() {
    load 'helpers/common'
    setup_http
}

@test "jenkins: internal login is ready but gateway requires authentication" {
    run compose_exec jenkins curl -sS -o /dev/null -w '%{http_code}' http://localhost:8080/login
    [ "$status" -eq 0 ]
    [ "$output" = 200 ]
    assert_healthy jenkins
    assert_http /jenkins 302
}
