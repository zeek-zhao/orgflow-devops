#!/usr/bin/env bats
setup() {
    load 'helpers/common'
    setup_gw
}

# #45：把 docker 能力从 controller 挪到独立 agent 之后，
# 三个 pipeline job 的 node('orgflow-docker') 才第一次真有节点可跑。
#
# 这里的断言刻意分成「容器层」和「Jenkins 层」两组：
# 容器起来了不代表 Jenkins 认到了节点，而节点在线也不代表 docker 能用 ——
# 后者是 job 里最常见的坑（CLI 在、sock 没挂，报 Cannot connect to the Docker daemon）。

@test "jenkins-agent: 容器健康、固定 IP、docker CLI 真能用" {
    assert_healthy jenkins-agent
    # 固定 IP 是排查锚点：架构图上的 172.31.0.27 必须真的是 agent
    assert_fixed_ip jenkins-agent 172.31.0.27

    # 镜像里必须真有 docker CLI，否则 job 里 docker build 直接 command not found
    run compose_exec jenkins-agent docker --version
    [ "$status" -eq 0 ]
    assert_contains "$output" "Docker version"

    # CLI 存在 ≠ 能连上 daemon：sock 没挂上时命令照样在，
    # 但会报 "Cannot connect to the Docker daemon"。这一条才是真正的连通性断言。
    run compose_exec jenkins-agent docker ps -q
    [ "$status" -eq 0 ]
}

@test "jenkins-agent: JCasC 建出的节点在线，且带 orgflow-docker 标签" {
    local admin pass info deadline
    admin=$(sed -n 's/^JENKINS_ADMIN_ID=//p' "$M0_ENV_FILE" | tail -1)
    pass=$(sed -n 's/^JENKINS_ADMIN_PASSWORD=//p' "$M0_ENV_FILE" | tail -1)
    [ -n "$admin" ]
    [ -n "$pass" ]

    # 直接打容器内 8080，不走网关：网关要求 oauth2 登录，测试里没有浏览器。
    # 节点是 retentionStrategy=always，Jenkins 启动后几秒内就会去连，
    # 但 SSH 握手 + agent jar 启动需要时间，所以轮询而不是只查一次。
    deadline=$((SECONDS + 120))
    while (( SECONDS <= deadline )); do
        info=$(compose_exec jenkins curl -sS -u "$admin:$pass" \
            'http://localhost:8080/computer/api/json?tree=computer[displayName,offline,assignedLabels[name]]' 2>/dev/null \
            | jq -r '.computer[]? | select(.displayName == "orgflow-docker")
                     | "\(.offline) \(.assignedLabels | map(.name) | join(","))"' 2>/dev/null || true)
        [[ $info == "false "* ]] && break
        sleep 3
    done

    if [[ $info != "false "* ]]; then
        echo "orgflow-docker 节点没在线，实际: '${info:-<空>}'" >&2
        echo "  空   → JCasC 没建出节点（configuration-as-code 没生效？）" >&2
        echo "  true → 节点建出来了但 SSH 连不上（密钥/主机名/凭据 id 对不上）" >&2
        compose_exec jenkins curl -sS -u "$admin:$pass" \
            'http://localhost:8080/computer/api/json?tree=computer[displayName,offline]' >&2 || true
        return 1
    fi

    assert_contains "$info" "orgflow-docker"
}
