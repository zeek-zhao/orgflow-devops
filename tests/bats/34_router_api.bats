#!/usr/bin/env bats
# #61 路由注册 API：POST → routes.yaml → 渲染 → Caddy 热加载，全链路不重启容器。
# routes.yaml 是唯一真源，API 只是写入口；反证是 400 时文件一个字节都不能动。
setup() {
    load 'helpers/common'
    setup_gw
    ROUTES="$M0_REPO/config/routes.yaml"
    CADDYFILE="$M0_REPO/out/Caddyfile"
    # router 镜像没有 curl，容器内用 python3 发请求
    api() {
        compose_cmd exec -T router python3 -c '
import json, sys, urllib.request, urllib.error
method, path = sys.argv[1], sys.argv[2]
data = sys.argv[3].encode() if len(sys.argv) > 3 and sys.argv[3] != "-" else None
req = urllib.request.Request("http://localhost:8090" + path, data=data, method=method)
try:
    with urllib.request.urlopen(req, timeout=10) as r:
        print(r.status); sys.stdout.write(r.read().decode())
except urllib.error.HTTPError as e:
    print(e.code); sys.stdout.write(e.read().decode())
' "$@"
    }
}

@test "router api: POST 一条路由 → 文件/Caddyfile/Caddy 三处全生效，不重启任何容器" {
    local before_sha after_sha baseline_routes
    before_sha=$(sha256sum "$ROUTES" | cut -d' ' -f1)
    baseline_routes=$(api GET /routes | sed -n '2,$p' | python3 -c 'import json,sys; print("\n".join(r["name"] for r in json.load(sys.stdin)["routes"]))')
    local jenkins_id
    jenkins_id=$(docker inspect -f '{{.Id}}' of-jenkins)

    run api POST /routes '{"name":"demo","host":"demo.'"${GW_DOMAIN}"'","upstream":"caddy:80"}'
    [ "$status" -eq 0 ]
    assert_contains "$output" "201"
    assert_contains "$output" '"subdomain": "demo"'

    # ① 文件里出现（host 是 FQDN，落盘为 subdomain 口径）
    grep -q "subdomain: demo" "$ROUTES"
    # ② Caddyfile 已重渲染
    grep -q "https://demo.${GW_DOMAIN} {" "$CADDYFILE"
    # ③ Caddy 真的加载了（issue 验收口径：admin /config/ 里有它，不是只写了文件）
    run compose_cmd exec -T router python3 -c '
import urllib.request
print(urllib.request.urlopen("http://caddy:2019/config/", timeout=10).read().decode())'
    if ! grep -q "demo" <<< "$output"; then
        echo "== /config/ 片段 == ${output:0:500}" >&2
        compose_cmd logs router --no-color 2>&1 | tail -8 >&2
    fi
    assert_contains "$output" "demo"
    # ④ 真实请求也走通：caddy:80 对已知域名做 80→443 跳转（308 证明站点已注册）
    assert_gw demo / 308
    # 全程没有容器重建
    [ "$(docker inspect -f '{{.Id}}' of-jenkins)" = "$jenkins_id" ]

    # GET：合法 JSON 且包含 demo
    run api GET /routes
    assert_contains "$output" '"demo"'
    local posted_route_names posted_route_count
    posted_route_names=$(sed -n '2,$p' <<< "$output" | python3 -c 'import json,sys; print("\n".join(r["name"] for r in json.load(sys.stdin)["routes"]))')
    posted_route_count=$(wc -l <<< "$posted_route_names")
    [ "$posted_route_count" -eq "$(($(wc -l <<< "$baseline_routes") + 1))" ]
    grep -Fxq demo <<< "$posted_route_names"
    while IFS= read -r route_name; do grep -Fxq "$route_name" <<< "$posted_route_names"; done <<< "$baseline_routes"

    # DELETE：恢复现场，文件 sha256 回到原值
    run api DELETE /routes/demo
    assert_contains "$output" "200"
    run api GET /routes
    local restored_routes
    restored_routes=$(sed -n '2,$p' <<< "$output" | python3 -c 'import json,sys; print("\n".join(r["name"] for r in json.load(sys.stdin)["routes"]))')
    [ "$restored_routes" = "$baseline_routes" ]
    after_sha=$(sha256sum "$ROUTES" | cut -d' ' -f1)
    [ "$before_sha" = "$after_sha" ]
    # 站点已删：握手必须失败（与 14_caddy 未知域名同口径，TLS alert / 非零退出）
    run curl -sS --max-time 20 -o /dev/null -w '%{http_code}' \
        --resolve "demo.${GW_DOMAIN}:${GW_HTTPS_PORT}:${GW_HOST}" \
        "https://demo.${GW_DOMAIN}:${GW_HTTPS_PORT}/"
    [ "$status" -ne 0 ]
}

@test "router api: 非法输入 400，routes.yaml 与 Caddyfile 原封不动（#61 关键反证）" {
    local routes_before caddy_before
    routes_before=$(sha256sum "$ROUTES" | cut -d' ' -f1)
    caddy_before=$(sha256sum "$CADDYFILE" | cut -d' ' -f1)

    run api POST /routes '{"name":"demo","host":"","upstream":"homepage:3000"}'
    assert_contains "$output" "400"

    [ "$(sha256sum "$ROUTES" | cut -d' ' -f1)" = "$routes_before" ]
    [ "$(sha256sum "$CADDYFILE" | cut -d' ' -f1)" = "$caddy_before" ]
}

@test "router api: GET /routes 是合法 JSON；/healthz 照常工作" {
    run api GET /routes
    assert_contains "$output" "200"
    compose_cmd exec -T router python3 -m json.tool /dev/stdin <<< "${output#200}"
    run api GET /healthz
    assert_contains "$output" "200"
}
