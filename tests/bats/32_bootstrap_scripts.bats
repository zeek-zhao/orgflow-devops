#!/usr/bin/env bats
# 自举脚本的幂等/产物断言（#64 干净环境自举的脚本面收口）。
#
# 背景：#64 验证的是「从零起来」，这三条验证的是「跑第二遍不炸」——
#   - nexus-deploy.sh：绝不重建容器（重建换挂载点归属、可能坏 blobstore）
#   - gen-agent-key.sh：绝不覆盖密钥（覆盖 = agent 全部连不上）
#   - gen-hosts.sh：片段生成稳定，--write 落地后六条域名可解析
# 这些语义目前只有注释承诺，没有机器断言；谁破坏了幂等，这里立刻红。
#
# 编号 32：排在 30（会 stop/start ldap）之后，自身不重启任何服务。

setup() {
    load 'helpers/common'
    setup_gw
}

@test "nexus-deploy: 容器已存在时重跑幂等——复用、不重建、不换 IP" {
    # entrypoint 已用 config id 拉起过 nexus；这里以「job 跑第二遍」的口径重跑
    local id_before started_before ip_before
    id_before="$(docker inspect -f '{{.Id}}' of-nexus)"
    started_before="$(docker inspect -f '{{.State.StartedAt}}' of-nexus)"
    ip_before="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' of-nexus)"
    [ -n "$id_before" ]

    # NEXUS_IMAGE 用现有容器的镜像（与被测代码同口径：已存在就别碰镜像）
    local image
    image="$(docker inspect -f '{{.Config.Image}}' of-nexus)"
    run env NEXUS_IMAGE="$image" \
        NEXUS_ADMIN_ID="$(sed -n 's/^NEXUS_ADMIN_ID=//p' "$M0_ENV_FILE" | tail -1)" \
        NEXUS_ADMIN_PASSWORD="$(sed -n 's/^NEXUS_ADMIN_PASSWORD=//p' "$M0_ENV_FILE" | tail -1)" \
        bash "$M0_REPO/scripts/nexus-deploy.sh"
    [ "$status" -eq 0 ]
    assert_contains "$output" "已存在"
    assert_contains "$output" "复用"

    # Id 与 StartedAt 不变 = 容器从未被重建/重启
    [ "$(docker inspect -f '{{.Id}}' of-nexus)" = "$id_before" ]
    [ "$(docker inspect -f '{{.State.StartedAt}}' of-nexus)" = "$started_before" ]
    [ "$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' of-nexus)" = "$ip_before" ]
}

@test "gen-agent-key: 重跑幂等——四个密钥文件字节不变、权限不受影响" {
    local dir="$M0_REPO/secrets"
    local before after
    before="$(cat "$dir/agent_ssh_key" "$dir/agent_ssh_key.pub" \
                  "$dir/agent_host_key" "$dir/agent_host_key.pub" | sha256sum)"

    run bash "$M0_REPO/scripts/gen-agent-key.sh"
    [ "$status" -eq 0 ]
    assert_contains "$output" "复用已有 agent 密钥"
    assert_contains "$output" "复用已有 agent host key"

    after="$(cat "$dir/agent_ssh_key" "$dir/agent_ssh_key.pub" \
                "$dir/agent_host_key" "$dir/agent_host_key.pub" | sha256sum)"
    [ "$after" = "$before" ]

    # umask 077 的约定：私钥必须 0600（宽了就是凭据泄漏面）
    [ "$(stat -c %a "$dir/agent_ssh_key")" = 600 ]
    [ "$(stat -c %a "$dir/agent_host_key")" = 600 ]
}

@test "gen-hosts: 片段含全部六域名与指定 IP，--write 落地后 getent 可解析" {
    local ip=127.0.0.1
    run bash "$M0_REPO/scripts/gen-hosts.sh" "$ip"
    [ "$status" -eq 0 ]
    assert_contains "$output" "$ip jenkins.$GW_DOMAIN nexus.$GW_DOMAIN ldapadmin.$GW_DOMAIN dex.$GW_DOMAIN auth.$GW_DOMAIN home.$GW_DOMAIN"

    # 不带 --write 不得改 hosts（片段生成是纯 stdout 动作）
    local hosts_before hosts_after
    hosts_before="$(cat /etc/hosts)"
    bash "$M0_REPO/scripts/gen-hosts.sh" "$ip" >/dev/null
    hosts_after="$(cat /etc/hosts)"
    [ "$hosts_after" = "$hosts_before" ]

    # --write：DinD 内层容器的 /etc/hosts 是一次性的，随便写
    bash "$M0_REPO/scripts/gen-hosts.sh" "$ip" --write >/dev/null
    for sub in jenkins nexus ldapadmin dex auth home; do
        getent hosts "$sub.$GW_DOMAIN" | grep -q "^$ip"
    done
}
