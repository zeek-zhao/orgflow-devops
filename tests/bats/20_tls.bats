#!/usr/bin/env bats
setup() {
    load 'helpers/common'
    setup_gw
    ROOT_CA=/tmp/orgflow-caddy-root.crt
}

@test "tls: 每个站点都出对应域名的证书，签发者是仓库自带的内部 CA" {
    cp "$M0_REPO/config/ca/orgflow-ca.crt" "$ROOT_CA"
    [ -s "$ROOT_CA" ]
    local sub info
    for sub in jenkins nexus ldapadmin dex auth ca; do
        info=$(echo | openssl s_client -connect "${GW_HOST}:${GW_HTTPS_PORT}" \
            -servername "${sub}.${GW_DOMAIN}" 2>/dev/null \
            | openssl x509 -noout -ext subjectAltName -issuer)
        # M0 起站点证书是 sign-certs.py 用 config/ca/ 那把 CA 签的叶子证书：
        # subject=CN=<子域>、SAN 只含该子域、issuer 是 orgflow-devops internal CA。
        # 断言 SAN（浏览器认的就是它）与签发者，不看 subject 的写法细节。
        assert_contains "$info" "DNS:${sub}.${GW_DOMAIN}"
        assert_contains "$info" "orgflow-devops internal CA"
    done
}

@test "tls: 导出的根证书能校验整条链（不带 -k 也通）" {
    cp "$M0_REPO/config/ca/orgflow-ca.crt" "$ROOT_CA"
    [ -s "$ROOT_CA" ]
    local entry sub path expected
    # dex 的端点都在 /dex 下，根路径本来就是 404，不能拿 / 当探针；
    # ldapadmin 已摘网关(#86):未登录直达 phpLDAPadmin 自身页面;docs 未登录 302 跳网关
    for entry in "nexus:/:200" "ldapadmin:/:200" "dex:/dex/healthz:200" "docs:/oauth2/start:302"; do
        sub=${entry%%:*}
        path=${entry#*:}; path=${path%%:*}
        expected=${entry##*:}
        run curl -sS --max-time 20 -o /dev/null -w '%{http_code}' --cacert "$ROOT_CA" \
            --resolve "${sub}.${GW_DOMAIN}:${GW_HTTPS_PORT}:${GW_HOST}" \
            "https://${sub}.${GW_DOMAIN}:${GW_HTTPS_PORT}${path}"
        [ "$status" -eq 0 ]
        [ "$output" = "$expected" ]
    done
}

@test "tls: 不信任内部 CA 时握手必须失败（证明不是公共证书）" {
    # 反证：如果这里意外返回 200，说明证书来自公共 CA，自签前提不成立
    run curl -sS --max-time 20 -o /dev/null -w '%{http_code}' \
        --resolve "nexus.${GW_DOMAIN}:${GW_HTTPS_PORT}:${GW_HOST}" \
        "https://nexus.${GW_DOMAIN}:${GW_HTTPS_PORT}/"
    [ "$status" -ne 0 ]
}
