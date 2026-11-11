#!/usr/bin/env bats
# #86 网关权限收口:oauth2-proxy 只守文档站,按 docs-users 组授权。
# 硬判据:非组成员完成 OIDC 后访问受保护路由必须被拒;组成员放行。
setup() {
    load 'helpers/common'
    setup_gw
}

@test "gateway acl: forward_auth 只剩文档站 1 处,jenkins/ldapadmin 已摘" {
    [ "$(grep -c forward_auth "$M0_REPO/out/Caddyfile")" -eq 1 ]
    grep -q "https://docs.${GW_DOMAIN} {" "$M0_REPO/out/Caddyfile"
    ! grep -q "https://jenkins.${GW_DOMAIN} {" <<< "$(grep -B1 -A6 forward_auth "$M0_REPO/out/Caddyfile")"
}

@test "gateway acl: oauth2-proxy 参数收紧(allowed-group/单域 cookie/无发布端口)" {
    run compose_cmd config --format json
    [ "$status" -eq 0 ]
    compose_cmd config --format json | python3 -c '
import json, sys
cfg = json.load(sys.stdin)
svc = cfg["services"]["oauth2-proxy"]
cmd = " ".join(svc.get("command", []))
assert "allowed-group=docs-users" in cmd, cmd
assert "cookie-domain=docs." in cmd, cmd
assert "email-domain=*" not in cmd
assert not svc.get("ports"), "oauth2-proxy 不得发布端口(伪造防线=网络隔离)"
assert svc.get("expose"), "4180 必须 expose 给 orgflow 网络"
print("OK")'
}

@test "gateway acl: 组成员(svc-platform-dev)完成 OIDC 后访问文档站放行" {
    # 口令真值只在 .env；硬编码 123456 在口令随机化之后会把这条测成「登录失败」，
    # 而失败信息看起来像权限问题 —— 假红的典型来源，见 helpers/common.bash
    local pass target
    pass=$(ldap_initial_password) || return 1
    # 靶子必须真的在 docs/ 里：Caddy 是 `root * /srv/docs` + file_server 直出原始
    # md，所以「文件不存在」和「没权限」都会表现成非 200，只看状态码分不开。
    # 原先取的是 /待办.md —— 该文件从未进过 main（只在未合并分支上），且被
    # gen_docs_site.py 的 EXCLUDE_FILES 列为不公开，于是这条用例一直假红在 404 上，
    # 看起来却像拦错了人。现在先断言靶子存在，再断言放行。
    target=/network/arch.md
    [ -f "$M0_REPO/docs${target}" ] || {
        echo "靶子文件不存在：docs${target}（是它没了，不是权限问题）" >&2
        return 1
    }
    # 登录落地页是站根 /，docs/ 下没有 index.html，所以那一跳 404 属预期（内容生成属 C2）；
    # 判定只看会话建立后取靶子的那一跳。
    run python3 "$M0_REPO/tests/bats/helpers/oidc_flow.py" \
        "docs.${GW_DOMAIN}" "${GW_HTTPS_PORT}" svc-platform-dev "$pass" "$target"
    echo "flow: $output" >&2
    [ "$status" -eq 0 ]
    assert_contains "$output" "POST-LOGIN-FETCH 200"
}

@test "gateway acl: 反证——口令错时不得拿登录页的 200 冒充放行" {
    # 这条是为上一条兜底的。fetch 会跟随 302，Dex 登录页本身返回 200，所以
    # 「会话没建立、被甩到登录页」在过去看起来和「已放行、拿到文件」一模一样：
    # 状态码都是 200。上一条改成先登录成功再取真实文件之后，这里显式按住反面——
    # 故意用错口令，必须拿不到 "POST-LOGIN-FETCH 200"。
    local target=/network/arch.md
    run python3 "$M0_REPO/tests/bats/helpers/oidc_flow.py" \
        "docs.${GW_DOMAIN}" "${GW_HTTPS_PORT}" svc-platform-dev \
        'not-the-real-password' "$target"
    echo "flow: $output" >&2
    refute_contains "$output" "POST-LOGIN-FETCH 200"
}

@test "gateway acl: 非组成员(svc-jira-dev)完成 OIDC 后必须被拒" {
    local pass
    pass=$(ldap_initial_password) || return 1
    run python3 "$M0_REPO/tests/bats/helpers/oidc_flow.py" \
        "docs.${GW_DOMAIN}" "${GW_HTTPS_PORT}" svc-jira-dev "$pass"
    echo "flow: $output" >&2
    # oauth2-proxy 在 allowed-group 不匹配时拒绝:403(登录页报 Access Denied)
    assert_contains "$output" "403"
}
