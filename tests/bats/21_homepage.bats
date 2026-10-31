#!/usr/bin/env bats
setup() {
    load 'helpers/common'
    setup_gw
}

# 统一入口是「所有服务都在这」的那一页，所以它同时验证两件事：
#   1. homepage 这个服务真的起来了、真的挂在 home 子域上
#   2. 服务卡片没被 YAML 缩进错误吃掉（写错一层整段失效，页面照样 200）

@test "homepage: 统一入口可达，且服务卡片都在" {
    assert_gw home / 200

    run gw_body home /
    [ "$status" -eq 0 ]

    local name
    for name in Jenkins Nexus "LDAP Admin" Dex Homepage; do
        grep -qi "$name" <<< "$output" || {
            echo "缺少卡片: $name" >&2
            return 1
        }
    done
}

@test "homepage: 卡片链接用的是配置里的域名，模板没有残留" {
    run gw_body home /
    [ "$status" -eq 0 ]

    # 环境变量没注入时，href 会原样渲染成 https://jenkins.{{HOMEPAGE_VAR_GATEWAY_DOMAIN}}
    # 页面看起来正常，点进去是坏的。这条专门拦这种情况。
    if grep -q '{{HOMEPAGE_VAR_' <<< "$output"; then
        echo "模板没展开：HOMEPAGE_VAR_GATEWAY_DOMAIN 没注入" >&2
        return 1
    fi

    # 卡片必须指向当前配置的域名，而不是某个写死的域名
    grep -qi "jenkins\.${GW_DOMAIN}" <<< "$output" || {
        echo "卡片链接里没有 jenkins.${GW_DOMAIN}" >&2
        return 1
    }
}
