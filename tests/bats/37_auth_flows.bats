#!/usr/bin/env bats
# #139 PR3 认证流:登录之后各服务真实可用（BDD 场景见 tests/features/37_auth_flows.feature）。
# 凭据真值只从 .env 读（svc-platform-admin / ORGFLOW_INITIAL_PASSWORD），不硬编码。
setup() {
    load 'helpers/common'
    setup_gw
}

teardown() {
    # 专用夹具清理：无论用例成败，Jenkins 里的 fixture Job 必须删除。
    # 夹具只在 Jenkins API 用例里创建（AUTH_FIXTURE_CREATED=1）。
    if [ -n "${AUTH_FIXTURE_JOB:-}" ] && [ "${AUTH_FIXTURE_CREATED:-}" = "1" ]; then
        local pass crumb_json crumb field
        pass=$(ldap_initial_password) || return 0
        local jar=/tmp/bdd-auth-cookiejar-teardown
        crumb_json=$(gw_curl jenkins /crumbIssuer/api/json -u "svc-platform-admin:${pass}" -c "$jar") || return 0
        crumb=$(printf '%s' "$crumb_json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["crumb"])' 2>/dev/null)
        field=$(printf '%s' "$crumb_json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["crumbRequestField"])' 2>/dev/null)
        [ -n "$crumb" ] && [ -n "$field" ] && \
            gw_curl jenkins "/job/${AUTH_FIXTURE_JOB}/doDelete" \
                -u "svc-platform-admin:${pass}" -b "$jar" -H "${field}: ${crumb}" -o /dev/null
        echo "teardown: 夹具 Job ${AUTH_FIXTURE_JOB} 已删除" >&2
    fi
}

@test "auth: LDAP 服务账号 bind 正确口令成功，错误口令必须拒绝（反证）" {
    local pass
    pass=$(ldap_initial_password) || return 1
    run compose_exec ldap sh -c \
        'exec ldapwhoami -x -H ldap://localhost:389 -D "uid=svc-platform-admin,ou=users,dc=devops,dc=com" -w "$1"' \
        sh "$pass"
    echo "whoami: $output" >&2
    [ "$status" -eq 0 ]
    # 反证：错误口令必须被 INVALID_CREDENTIALS 拒绝，否则第一条是假绿
    run compose_exec ldap sh -c \
        'exec ldapwhoami -x -H ldap://localhost:389 -D "uid=svc-platform-admin,ou=users,dc=devops,dc=com" -w "$1"' \
        sh "deliberately-wrong-${pass:0:4}"
    [ "$status" -ne 0 ]
    assert_contains "$output" "Invalid credentials"
}

@test "auth: 组授权真源——docs-users 由 posixGroup 决定（svc-platform-dev 在内，svc-jira-dev 不在）" {
    run compose_exec ldap sh -c \
        'exec ldapsearch -x -H ldap://localhost:389 -D cn=admin,dc=devops,dc=com -w "$LDAP_ADMIN_PASSWORD" -b ou=groups,dc=devops,dc=com "(cn=docs-users)" memberUid' \
        sh
    echo "search: $output" >&2
    [ "$status" -eq 0 ]
    # groups OU 下有子 OU（实测 ou=docs,ou=groups,...），按 RDN 前缀断言，不钉完整 DN
    assert_contains "$output" "dn: cn=docs-users,"
    assert_contains "$output" "memberUid: svc-platform-dev"
    # 反证面：非组成员账号绝不能出现在授权组里（36 号文件的 403 断言靠它成立）
    ! grep -q "memberUid: svc-jira-dev" <<< "$output"
}

@test "auth: 完整 OIDC 登录建立会话——会话内取受保护页放行，伪造会话必须回登录页（反证）" {
    local pass target
    pass=$(ldap_initial_password) || return 1
    target=/network/arch.md
    [ -f "$M0_REPO/docs${target}" ] || {
        echo "靶子文件不存在：docs${target}（是它没了，不是权限问题）" >&2
        return 1
    }
    # 正向：oauth2→Dex→LDAP→approval 完整走一遍，同一会话内取受保护页
    run python3 "$M0_REPO/tests/bats/helpers/oidc_flow.py" \
        "docs.${GW_DOMAIN}" "${GW_HTTPS_PORT}" svc-platform-dev "$pass" "$target"
    echo "flow: $output" >&2
    [ "$status" -eq 0 ]
    assert_contains "$output" "POST-LOGIN-FETCH 200"
    # 反证：伪造会话 Cookie 不得拿到受保护内容——oauth2-proxy 对无效会话回 302
    # 到 /oauth2/start。不能 -L 跟随：Location 是不带端口的正式域名，DinD 里
    # 443 未映射（CI 43571510512 实证 curl(7)），只看首跳状态与跳转目标。
    local probe
    probe=$(gw_curl docs "$target" -H "Cookie: _oauth2_proxy=forged-invalid-session" \
        -o /dev/null -w '%{http_code} %{redirect_url}')
    echo "probe: $probe" >&2
    case "$probe" in
        "302 "*"/oauth2/start"*) ;;
        *) { echo "无效会话未按预期甩回登录流: $probe" >&2; return 1; } ;;
    esac
}

@test "auth: Jenkins API 用 LDAP 凭据建 Job→触发构建→SUCCESS→删除（专用夹具+清理）" {
    local pass crumb_json crumb field code job result i
    job=bdd-auth-fixture
    pass=$(ldap_initial_password) || return 1
    AUTH_FIXTURE_JOB=$job
    # crumb：口令凭据的写操作必须带 CSRF crumb（API token 属 PR4 的 B4 用例）
    # crumb 绑定 web 会话 cookie（CI 43571510512：纯 basic-auth 的 crumb POST 403），
    # crumb 获取与所有写操作共用一个 cookie jar
    local jar=/tmp/bdd-auth-cookiejar
    rm -f "$jar"
    crumb_json=$(gw_curl jenkins /crumbIssuer/api/json -u "svc-platform-admin:${pass}" -c "$jar")
    assert_contains "$crumb_json" '"crumb"'
    crumb=$(printf '%s' "$crumb_json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["crumb"])')
    field=$(printf '%s' "$crumb_json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["crumbRequestField"])')
    # 幂等预清理：上次运行残留的夹具先删掉，保证 createItem 一定走新建
    gw_curl jenkins "/job/${job}/doDelete" -u "svc-platform-admin:${pass}" \
        -b "$jar" -H "${field}: ${crumb}" -o /dev/null
    # 建 freestyle 夹具 Job（echo 一步，最小可构建）
    # 澶瑰叿蹇呴』缁?orgflow-docker 鏍囩锛歝onfig/job_definitions/* 鐨勭湡瀹?Job 鍏ㄧ敤
    # agent {{ label 'orgflow-docker' }}锛涗笉缁戞爣绛剧殑 Job 鍙兘钀藉湪 0 鎵ц鍣ㄧ殑
    # built-in 鑺傜偣涓婏紝姘歌繙 pending锛圕I 43576824915 瀹炶瘉锛塡n    printf '%s' "<project><description>#139 auth fixture, deleted after test</description><assignedNode>orgflow-docker</assignedNode><canRoam>false</canRoam><builders><hudson.tasks.Shell><command>echo bdd-auth-fixture</command></hudson.tasks.Shell></builders></project>"
        > /tmp/bdd-auth-fixture.xml
    code=$(gw_curl jenkins "/createItem?name=${job}" -u "svc-platform-admin:${pass}" \
        -b "$jar" -H "${field}: ${crumb}" -H "Content-Type: text/xml" \
        --data-binary @/tmp/bdd-auth-fixture.xml -o /dev/null -w '%{http_code}')
    [ "$code" = "200" ] || { echo "createItem: $code" >&2; return 1; }
    AUTH_FIXTURE_CREATED=1
    # 触发构建
    code=$(gw_curl jenkins "/job/${job}/build?delay=0sec" -u "svc-platform-admin:${pass}" \
        -b "$jar" -H "${field}: ${crumb}" -X POST -o /dev/null -w '%{http_code}')
    [ "$code" = "201" ] || { echo "build trigger: $code" >&2; return 1; }
    # 轮询构建结果（上限约 120s：入队 + agent 领任务）
    result=""
    for i in $(seq 1 40); do
        # 入队期间 /lastBuild 尚不存在（404 非 JSON），解析失败必须容错继续轮询，
        # 不能让 set -e 在此处中止（CI 43574801372 实证）
        result=$(gw_curl jenkins "/job/${job}/lastBuild/api/json" -u "svc-platform-admin:${pass}" \
            | python3 -c 'import json,sys
try:
    d = json.load(sys.stdin)
    print(d.get("result") or "")
except Exception:
    print("")' 2>/dev/null) || true
        case "$result" in
            SUCCESS|FAILURE|ABORTED) break ;;
        esac
        sleep 3
    done
    echo "lastBuild result: ${result:-pending}" >&2
    [ "$result" = "SUCCESS" ]
}
