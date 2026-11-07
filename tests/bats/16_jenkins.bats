#!/usr/bin/env bats
setup() {
    load 'helpers/common'
    setup_gw
}

@test "jenkins: internal login is ready but the gateway requires authentication" {
    run compose_exec jenkins curl -sS -o /dev/null -w '%{http_code}' http://localhost:8080/login
    [ "$status" -eq 0 ]
    [ "$output" = 200 ]
    assert_healthy jenkins
    # 固定 IP 是排查锚点：架构图上的 172.31.0.20 必须真的是 Jenkins
    assert_fixed_ip jenkins 172.31.0.20
    assert_gw jenkins / 403
    # 未登录绝不返回 200：受保护站点不能漏认证
    run gw_code jenkins /
    [ "$output" != 200 ]
}
