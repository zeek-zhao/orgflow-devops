#!/usr/bin/env bats
setup() {
    load 'helpers/common'
    setup_gw
}

@test "ldapadmin: 管理面站点已摘网关(#86):未登录直达 phpLDAPadmin 自身页面(自带 LDAP 登录)" {
    assert_gw ldapadmin / 200
    # 跳转目标必须是认证站点，且带回原地址（rd=），登录后才能回到 ldapadmin
    local location
    location=$(gw_header ldapadmin / Location)
    [[ "$location" == "https://${GW_AUTH}.${GW_DOMAIN}/oauth2/start"* ]]
    [[ "$location" == *"rd="* ]]
}
