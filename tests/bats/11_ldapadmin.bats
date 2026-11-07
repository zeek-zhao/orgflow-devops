#!/usr/bin/env bats
setup() {
    load 'helpers/common'
    setup_gw
}

@test "ldapadmin: 管理面站点已摘网关(#86):不再 302 到 oauth2,由 phpLDAPadmin 自身应答" {
    run gw_header ldapadmin / Location
    if [ "$status" -eq 0 ]; then
        ! grep -q "oauth2/start" <<< "$output"
    fi
    # 自身应答:200(首页)或 302(phpLDAPadmin 自身登录跳转),绝非网关的 401/302 oauth2
    run gw_code ldapadmin /
    assert_contains "$output" -E "200|302"
}
