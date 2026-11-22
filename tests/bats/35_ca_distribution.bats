#!/usr/bin/env bats
# #62 根证书分发：router 服务 out/ca/，局域网机器从 https://ca.<domain>/ 一条命令装根证书。
# 「在干净机器上装」用一次性容器模拟：装进它自己的信任库，不污染 harness。
setup() {
    load 'helpers/common'
    setup_gw
    CA_DIR="$M0_REPO/out/ca"
    mkdir -p "$CA_DIR"
    # 导出当前内层 Caddy 的根证书 + 脚本（等价于在网关机跑 ca-install.sh --export）
    cp "$M0_REPO/config/ca/orgflow-ca.crt" "$CA_DIR/root.crt"
    cp "$M0_REPO/scripts/21-ca-install.sh" "$CA_DIR/ca-install.sh"
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
        | openssl x509 -noout -subject -dates"
    [ "$status" -eq 0 ]
    # M0 起根证书是入库的 orgflow 内部 CA（自签、10 年期），不再是 Caddy 自签的
    # Local Authority —— 后者 `down -v` 就换一把，客户端得重装。
    assert_contains "$output" "orgflow-devops internal CA"
    assert_contains "$output" "notAfter=Nov"
}

@test "ca-install.sh 远程模式: 干净容器一条命令装根证书并复验通过" {
    # 宿主→网关的域名解析在测试栈里由 --resolve 提供；干净机器没有这一层，
    # 所以这里用 --add-host 模拟 `make hosts` 写好的 hosts（网关 IP 用宿主 aliases 里那个）
    local gw_ip
    gw_ip=$(compose_cmd exec -T caddy sh -c "hostname -i" | tr -d '\r' | awk '{print $1}')
    [ -n "$gw_ip" ]
    local hosts_args=()
    for sub in jenkins nexus docker pypi ldapadmin dex auth home ca docs; do
        hosts_args+=(--add-host "${sub}.${GW_DOMAIN}:${gw_ip}")
    done
    # ubuntu 基座在构建缓存里现成；apt 装 curl/openssl 模拟「干净机器」
    run docker run --rm --network orgflow --dns 172.31.0.2 \
        "${hosts_args[@]}" \
        -v "$CA_DIR:/ca:ro" \
        -e GATEWAY_DOMAIN="$GW_DOMAIN" \
        ubuntu:24.04 bash -c '
        set -e
        apt-get update -qq >/dev/null && apt-get install -y -qq curl openssl ca-certificates >/dev/null
        # 反证在前：网关地址错了必须非零退出并打印原因
        if bash /ca/ca-install.sh https://ca-gone.'"${GW_DOMAIN//./\\.}"' 2>/dev/null; then
            echo "反证失败：错误地址竟然成功了"; exit 97
        fi
        # 测试栈网关不监听 443（端口由 GW_HTTPS_PORT 指定），所以地址里必须带端口；
        # 真实部署 443 是默认值，地址里可以省略。
        bash /ca/ca-install.sh "https://ca.${GATEWAY_DOMAIN}:${GW_HTTPS_PORT}"
        openssl x509 -in /usr/local/share/ca-certificates/orgflow-caddy.crt -noout -subject | grep -o "orgflow-devops internal CA"
        # 复验：脚本内部已不带 -k 打通；这里再打一次别的站点证明整条链
        curl -fsS --max-time 20 -o /dev/null "https://nexus.${GATEWAY_DOMAIN}/"
        echo INSTALL_AND_VERIFY_OK'
    [ "$status" -eq 0 ]
    assert_contains "$output" "INSTALL_AND_VERIFY_OK"
    assert_contains "$output" "orgflow-devops internal CA"
}
