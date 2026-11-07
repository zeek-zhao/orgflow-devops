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
    # 会话建立后取真实文件 README.md → 200(放行证明;404 期内容生成属 C2)
    run python3 "$M0_REPO/tests/bats/helpers/oidc_flow.py" \
        "docs.${GW_DOMAIN}" "${GW_HTTPS_PORT}" svc-platform-dev '123456' /%E5%BE%85%E5%8A%9E.md
    echo "flow: $output" >&2
    [ "$status" -eq 0 ]
    assert_contains "$output" "POST-LOGIN-FETCH 200"
}

@test "gateway acl: 非组成员(svc-jira-dev)完成 OIDC 后必须被拒" {
    run python3 "$M0_REPO/tests/bats/helpers/oidc_flow.py" \
        "docs.${GW_DOMAIN}" "${GW_HTTPS_PORT}" svc-jira-dev '123456'
    echo "flow: $output" >&2
    # oauth2-proxy 在 allowed-group 不匹配时拒绝:403(登录页报 Access Denied)
    assert_contains "$output" "403"
}
