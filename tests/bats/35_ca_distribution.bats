#!/usr/bin/env bats
# #62 根证书分发：router 服务 out/ca/，局域网机器从 https://ca.<domain>/ 一条命令装根证书。
# 「在干净机器上装」用一次性容器模拟：装进它自己的信任库，不污染 harness。
setup() {
    load 'helpers/common'
    setup_gw
    CA_DIR="$M0_REPO/out/ca"
    mkdir -p "$CA_DIR"
    # 导出当前内层 Caddy 的根证书 + 脚本（等价于在网关机跑 ca-install.sh --export）
    compose_cmd exec -T caddy cat /data/caddy/pki/authorities/local/root.crt > "$CA_DIR/root.crt"
    cp "$M0_REPO/scripts/ca-install.sh" "$CA_DIR/ca-install.sh"
    [ -s "$CA_DIR/root.crt" ]
}

teardown() {
    rm -rf "$CA_DIR"
}

@test "ca 站点: root.crt 与安装脚本都能经网关拉取，证书主题正确" {
    assert_gw ca /root.crt 200
    assert_gw ca /ca-install.sh 200
    run bash -c "curl -sk --resolve ca.${GW_DOMAIN}:${GW_HTTPS_PORT}:${GW_HOST} \
        https://ca.${GW_DOMAIN}:${GW_HTTPS_PORT}/root.crt \
        | openssl x509 -noout -subject"
    [ "$status" -eq 0 ]
    assert_contains "$output" "Caddy Local Authority"
}

@test "ca-install.sh 远程模式: 干净容器一条命令装根证书并复验通过" {
    # ubuntu 基座在构建缓存里现成；apt 装 curl/openssl 模拟「干净机器」
    run docker run --rm --network orgflow --dns 172.31.0.2 \
        -v "$CA_DIR:/ca:ro" \
        -e GATEWAY_DOMAIN="$GW_DOMAIN" \
        ubuntu:24.04 bash -c '
        set -e
        apt-get update -qq >/dev/null && apt-get install -y -qq curl openssl ca-certificates >/dev/null
        # 反证在前：网关地址错了必须非零退出并打印原因
        if bash /ca/ca-install.sh https://ca-gone.'"${GW_DOMAIN//./\\.}"' 2>/dev/null; then
            echo "反证失败：错误地址竟然成功了"; exit 97
        fi
        bash /ca/ca-install.sh "https://ca.${GATEWAY_DOMAIN}"
        openssl x509 -in /usr/local/share/ca-certificates/orgflow-caddy.crt -noout -subject | grep -o "Caddy Local Authority"
        # 复验：脚本内部已不带 -k 打通；这里再打一次别的站点证明整条链
        curl -fsS --max-time 20 -o /dev/null "https://nexus.${GATEWAY_DOMAIN}/"
        echo INSTALL_AND_VERIFY_OK'
    [ "$status" -eq 0 ]
    assert_contains "$output" "INSTALL_AND_VERIFY_OK"
    assert_contains "$output" "Caddy Local Authority"
}
