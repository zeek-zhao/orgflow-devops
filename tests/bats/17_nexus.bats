#!/usr/bin/env bats
setup() {
    load 'helpers/common'
    setup_gw
}

# #46：Nexus 从 compose 里摘出来，改由 Jenkins job `nexus-deploy` 部署。
#
# 这里测的是「跑完 job 之后」的状态 —— harness 在 compose 起来之后会执行
# scripts/nexus-deploy.sh，等价于跑完那个 job。
#
# 分三层，因为它们的失败原因完全不同：
#   1. 网关层：站点 200 / status API 200 —— Caddy 的上游解析对不对
#   2. 容器层：固定 IP / health / 网络别名 —— docker run 的参数对不对
#   3. 交付层：幂等 / 改密 —— job 能不能重复跑、密码是不是配置里那个

@test "nexus: 网关 200、status API 200、容器健康且落在 172.31.0.21" {
    assert_gw nexus / 200
    assert_gw nexus /service/rest/v1/status 200
    assert_container_healthy of-nexus
    assert_container_ip of-nexus 172.31.0.21
    # 网络别名 nexus 是 Caddy 上游的解析目标。docker run 不像 compose 那样
    # 自动把服务名变成别名，漏了就是整站 502，而且报错只说 upstream 不可达。
    assert_resolves_in_container caddy nexus 172.31.0.21
}

@test "nexus: 由 nexus-deploy 创建，且不在 compose 服务列表里" {
    # 标签是「这个容器是谁创建的」的机器可读证据。
    # 没有它的话，`make deploy` 之后如果 nexus 意外起来了，
    # 测试根本分不清是脚本生效还是有人把它加回了 compose。
    [ "$(docker inspect -f '{{index .Config.Labels "orgflow.managed-by"}}' of-nexus)" = nexus-deploy ]

    run compose_cmd config --services
    [ "$status" -eq 0 ]
    ! printf '%s\n' "$output" | grep -qx nexus

    # 脚本里钉的镜像 digest 必须与 images.lock 一致：
    # 两处各写一遍是刻意的（job 跑在 213，只能拉 GHCR 的 mirror 包），
    # 但 digest 不能漂，漂了就是「备份的是 A 版本、跑的是 B 版本」。
    local locked
    locked="$(awk -F '\t' '$1 == "nexus" {print $3}' "$M0_REPO/tests/images.lock")"
    assert_contains "$(cat "$M0_REPO/scripts/nexus-deploy.sh")" "$locked"

    # 卷名必须与 scripts/backup-common.sh 里写死的一致。
    # 卷名一漂，备份脚本会备份一个空卷而真正的数据在另一个卷里 —— 静默出错，
    # 等要恢复的时候才发现，那时候已经没有「另一个卷」可用了。
    [ "$(docker inspect -f \
        '{{range .Mounts}}{{if eq .Destination "/nexus-data"}}{{.Name}}{{end}}{{end}}' \
        of-nexus)" = "orgflow-devops_nexus_data" ]
}

@test "nexus: 重跑 nexus-deploy 幂等，不重建容器" {
    local before after admin pass
    admin=$(sed -n 's/^NEXUS_ADMIN_ID=//p' "$M0_ENV_FILE" | tail -1)
    pass=$(sed -n 's/^NEXUS_ADMIN_PASSWORD=//p' "$M0_ENV_FILE" | tail -1)
    before="$(docker inspect -f '{{.Id}}' of-nexus)"

    # 带上密码重跑：走的是「容器已存在 + 密码已生效」这条真实幂等路径，
    # 不带密码会走到「跳过改密」的分支，测不到真正要测的那一半。
    run env NEXUS_ADMIN_ID="$admin" NEXUS_ADMIN_PASSWORD="$pass" \
        bash "$M0_REPO/scripts/nexus-deploy.sh"
    [ "$status" -eq 0 ]
    assert_contains "$output" "已存在"
    assert_contains "$output" "配置的密码已生效"

    after="$(docker inspect -f '{{.Id}}' of-nexus)"
    # 重建容器不丢数据（卷还在），但会丢掉「这个容器跑了两小时」这类状态，
    # 而且真机上重建 Nexus 要几分钟。幂等的意思就是不该重建。
    [ "$before" = "$after" ]
    assert_gw nexus / 200
}

@test "nexus: 初始密码文件已删除，配置的密码能登录" {
    local admin pass
    admin=$(sed -n 's/^NEXUS_ADMIN_ID=//p' "$M0_ENV_FILE" | tail -1)
    pass=$(sed -n 's/^NEXUS_ADMIN_PASSWORD=//p' "$M0_ENV_FILE" | tail -1)
    [ -n "$admin" ]
    [ -n "$pass" ]

    # admin.password 留着就等于留一把永不过期的后门，
    # 而且它是「改密确实做过」的唯一可靠标记（界面上不再提示改密）。
    run docker_exec of-nexus test -e /nexus-data/admin.password
    [ "$status" -ne 0 ]

    # 用配置的密码走一次真实的 REST 认证，而不是只看文件在不在。
    run docker_exec of-nexus curl -sS -o /dev/null -w '%{http_code}' \
        -u "$admin:$pass" \
        "http://localhost:8081/service/rest/v1/security/users?userId=$admin"
    [ "$status" -eq 0 ]
    [ "$output" = 200 ]
}
