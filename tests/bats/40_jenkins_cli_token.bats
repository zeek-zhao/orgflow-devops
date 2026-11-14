#!/usr/bin/env bats
# #139 PR4 Jenkins API token + CLI 四件套（BDD 场景见 tests/features/40_jenkins_cli_token.feature）。
# B4 的 bats 面：list/get/run/log 用 API token 真跑一轮。token 生成与撤销必须
# 在同一文件内完成——探针 2026-11-14 曾泄漏一个活 token，事后 revoke 收场，
# 不能重演；teardown 再兜底撤销。夹具 Job 用专用名字并在 teardown 删除。
setup() {
    load 'helpers/common'
    setup_gw
}

teardown() {
    local pass jar cj crumb field
    pass=$(ldap_initial_password) || return 0
    jar=/tmp/bdd-cli-jar-teardown
    cj=$(gw_curl jenkins /crumbIssuer/api/json -u "svc-platform-admin:${pass}" -c "$jar") || return 0
    crumb=$(printf '%s' "$cj" | python3 -c 'import json,sys; print(json.load(sys.stdin)["crumb"])' 2>/dev/null) || return 0
    field=$(printf '%s' "$cj" | python3 -c 'import json,sys; print(json.load(sys.stdin)["crumbRequestField"])' 2>/dev/null) || return 0
    if [ -n "${CLI_TOK_UUID:-}" ]; then
        gw_curl jenkins "/me/descriptorByName/jenkins.security.ApiTokenProperty/revoke" \
            -u "svc-platform-admin:${pass}" -b "$jar" -H "${field}: ${crumb}" \
            -d "tokenUuid=${CLI_TOK_UUID}" -o /dev/null || true
        echo "teardown: 兜底撤销 API token" >&2
    fi
    gw_curl jenkins "/job/bdd-cli-fixture/doDelete" \
        -u "svc-platform-admin:${pass}" -b "$jar" -H "${field}: ${crumb}" -o /dev/null || true
}

# LDAP 口令登录拿 crumb（crumb 绑定 web 会话 cookie，CI 43571510512 实证；
# crumb 获取与所有写操作共用一个 cookie jar），置 CLI_PASS/CLI_CRUMB/CLI_FIELD/CLI_JAR
cli_session() {
    CLI_JAR=/tmp/bdd-cli-jar
    CLI_PASS=$(ldap_initial_password) || return 1
    rm -f "$CLI_JAR"
    local cj
    cj=$(gw_curl jenkins /crumbIssuer/api/json -u "svc-platform-admin:${CLI_PASS}" -c "$CLI_JAR") || return 1
    CLI_CRUMB=$(printf '%s' "$cj" | python3 -c 'import json,sys; print(json.load(sys.stdin)["crumb"])') || return 1
    CLI_FIELD=$(printf '%s' "$cj" | python3 -c 'import json,sys; print(json.load(sys.stdin)["crumbRequestField"])') || return 1
}

# 生成 API token：<名字> → 置 CLI_TOK_UUID/CLI_TOK_VALUE。
# 端点与响应形状为探针 2026-11-14 实证：字段在 data.* 里，不在顶层。
cli_token_generate() {
    local name=$1 resp
    resp=$(gw_curl jenkins "/me/descriptorByName/jenkins.security.ApiTokenProperty/generateNewToken" \
        -u "svc-platform-admin:${CLI_PASS}" -b "$CLI_JAR" -H "${CLI_FIELD}: ${CLI_CRUMB}" \
        -d "tokenName=${name}") || return 1
    CLI_TOK_UUID=$(printf '%s' "$resp" | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"]["tokenUuid"])') || return 1
    CLI_TOK_VALUE=$(printf '%s' "$resp" | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"]["tokenValue"])') || return 1
    [ -n "$CLI_TOK_UUID" ] && [ -n "$CLI_TOK_VALUE" ]
}

cli_token_revoke() {
    gw_curl jenkins "/me/descriptorByName/jenkins.security.ApiTokenProperty/revoke" \
        -u "svc-platform-admin:${CLI_PASS}" -b "$CLI_JAR" -H "${CLI_FIELD}: ${CLI_CRUMB}" \
        -d "tokenUuid=${CLI_TOK_UUID}" -o /dev/null -w '%{http_code}'
}

@test "jenkins: API token 生命周期——生成→认证→错 token 401→撤销后 401" {
    local who code
    cli_session || return 1
    CLI_TOK_UUID= CLI_TOK_VALUE=
    cli_token_generate bdd-cli-probe || return 1
    # token 作 Basic 密码位认证（LDAP-only 栈；探针实证 whoAmI authenticated:true）
    who=$(gw_curl jenkins /whoAmI/api/json -u "svc-platform-admin:${CLI_TOK_VALUE}") || return 1
    assert_contains "$who" '"authenticated":true'
    # 反证：错误 token 必须被拒
    code=$(gw_curl jenkins /whoAmI/api/json -u "svc-platform-admin:deliberately-wrong-token" \
        -o /dev/null -w '%{http_code}')
    [ "$code" = "401" ]
    code=$(cli_token_revoke)
    echo "revoke: $code" >&2
    [ "$code" = "200" ]
    # 撤销后同一 token 必须 401——撤销真的收走了凭据
    code=$(gw_curl jenkins /whoAmI/api/json -u "svc-platform-admin:${CLI_TOK_VALUE}" \
        -o /dev/null -w '%{http_code}')
    [ "$code" = "401" ]
}

@test "jenkins: CLI 四件套用 API token 真跑——list/get/run/log(专用夹具+清理)" {
    local job xml code sent i msg
    job=bdd-cli-fixture
    sent="probe-msg-$(date +%s)"
    cli_session || return 1
    CLI_TOK_UUID= CLI_TOK_VALUE=
    cli_token_generate bdd-cli-run || return 1
    # 幂等预清理：残留夹具先删，保证 createItem 走新建
    gw_curl jenkins "/job/${job}/doDelete" -u "svc-platform-admin:${CLI_PASS}" \
        -b "$CLI_JAR" -H "${CLI_FIELD}: ${CLI_CRUMB}" -o /dev/null || true
    # 夹具：参数化 freestyle + echo；必须绑 orgflow-docker 标签（CI 43576824915：
    # 未绑标签只能落 0 执行器 built-in 节点，永远 pending）
    xml='<project><actions/><description>bdd cli fixture</description><keepDependencies>false</keepDependencies><properties><hudson.model.ParametersDefinitionProperty><parameterDefinitions><hudson.model.StringParameterDefinition><name>ECHO_MSG</name><defaultValue>hello</defaultValue></hudson.model.StringParameterDefinition></parameterDefinitions></hudson.model.ParametersDefinitionProperty></properties><assignedNode>orgflow-docker</assignedNode><canRoam>false</canRoam><disabled>false</disabled><builders><hudson.tasks.Shell><command>echo "cli fixture: ${ECHO_MSG}"</command></hudson.tasks.Shell></builders><publishers/><buildWrappers/></project>'
    code=$(gw_curl jenkins "/createItem?name=${job}" -u "svc-platform-admin:${CLI_PASS}" \
        -b "$CLI_JAR" -H "${CLI_FIELD}: ${CLI_CRUMB}" -H "Content-Type: application/xml" \
        --data-binary "$xml" -o /dev/null -w '%{http_code}')
    echo "createItem: $code" >&2
    [ "$code" = "200" ]
    # 四件套：凭据走环境变量（脚本优先读环境变量），token 作密码位；
    # CLI 直连容器固定 IP，不走网关（forward_auth 会把 API 请求 302 到 Dex）
    export JENKINS_ADMIN_ID=svc-platform-admin
    export JENKINS_ADMIN_PASSWORD="$CLI_TOK_VALUE"
    run bash "$M0_REPO/scripts/jenkins-cli.sh" list
    echo "cli list: ${output:0:160}" >&2
    [ "$status" -eq 0 ]
    assert_contains "$output" "${job}"
    run bash "$M0_REPO/scripts/jenkins-cli.sh" get "$job"
    [ "$status" -eq 0 ]
    assert_contains "$output" "ECHO_MSG"
    run bash "$M0_REPO/scripts/jenkins-cli.sh" run "$job" "ECHO_MSG=${sent}"
    echo "cli run: ${output:0:160}" >&2
    [ "$status" -eq 0 ]
    assert_contains "$output" "201"
    # log：构建在 agent 上跑（探针 2026-11-14 实证 ~9s），轮询等 echo 行出现
    msg="cli fixture: ${sent}"
    for i in $(seq 1 30); do
        run bash "$M0_REPO/scripts/jenkins-cli.sh" log "$job" last || true
        if [[ "$output" == *"${msg}"* ]]; then break; fi
        sleep 3
    done
    echo "cli log: ${output:0:200}" >&2
    assert_contains "$output" "${msg}"
}
