#!/usr/bin/env bats
setup() {
    load 'helpers/common'
    setup_gw
}

# 只用确认带 shell 的容器做解析断言：oauth2-proxy 是 distroless，
# dex 的精简镜像也不保证有 sh/getent，拿它们 exec 会得到与 DNS 无关的失败。
@test "dns: dnsmasq 把整个网关域名段解析到 Caddy 的固定 IP" {
    assert_healthy dnsmasq
    assert_fixed_ip dnsmasq 172.31.0.2
    run compose_exec dnsmasq dig +short +time=2 +tries=1 "jenkins.${GW_DOMAIN}" @172.31.0.2
    [ "$status" -eq 0 ]
    assert_contains "$output" "172.31.0.10"
}

@test "dns: 容器内能用域名互访（服务端到服务端不绕公网）" {
    # 验收条目原文：docker compose exec caddy getent hosts nexus.<domain>
    assert_resolves_in caddy "nexus.${GW_DOMAIN}" 172.31.0.10
    assert_resolves_in caddy "jenkins.${GW_DOMAIN}" 172.31.0.10
    assert_resolves_in jenkins "dex.${GW_DOMAIN}" 172.31.0.10
    # nexus 不是 compose 服务（#46），按容器名 exec
    assert_resolves_in_container of-nexus "auth.${GW_DOMAIN}" 172.31.0.10
}

@test "dns: 服务名仍然可解析（dnsmasq 转发给 Docker 内嵌 DNS）" {
    assert_resolves_in caddy nexus 172.31.0.21
    assert_resolves_in jenkins ldap 172.31.0.22
    # nexus 不是 compose 服务（#46），按容器名查；它的底座镜像工具少，
    # 断言里会按 getent → nslookup → dig → curl 逐级降级。
    assert_resolves_in_container of-nexus "auth.${GW_DOMAIN}" 172.31.0.10
}

@test "dns: nexus 容器也把 dnsmasq 当 resolver（不是 Docker 内嵌 DNS）" {
    # docker run 不带 --dns 时会退回 127.0.0.11，那样 *.org-devops.com 解析不了，
    # 而症状是「容器能起来但访问网关域名失败」，看起来像网络问题。
    run docker_exec of-nexus cat /etc/resolv.conf
    [ "$status" -eq 0 ]
    assert_contains "$output" "172.31.0.2"
}

@test "dns: 固定 IP 表与架构图一致（排查时按 IP 定位容器）" {
    assert_fixed_ip caddy 172.31.0.10
    assert_fixed_ip router 172.31.0.11
    assert_fixed_ip jenkins 172.31.0.20
    # nexus 的 IP 由 scripts/nexus-deploy.sh 的 --ip 决定，不在 compose 里
    assert_container_ip of-nexus 172.31.0.21
    assert_fixed_ip ldap 172.31.0.22
    assert_fixed_ip ldapadmin 172.31.0.23
    assert_fixed_ip dex 172.31.0.24
    assert_fixed_ip oauth2-proxy 172.31.0.25
}
