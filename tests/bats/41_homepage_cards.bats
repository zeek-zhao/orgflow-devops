#!/usr/bin/env bats
# #139 PR4 Homepage 入口逐链接实访（BDD 场景见 tests/features/41_homepage_cards.feature）。
# C1 用户面：入口页上每个链接点开都不能是死的。/api/services 是内网服务卡片
# （探针 2026-11-14：6 张）；/api/bookmarks 全部是外链（GitHub 文档镜像、上游
# 官方文档），DinD 无外网，只断言它们是格式完整的 https URL，不做实访。
setup() {
    load 'helpers/common'
    setup_gw
}

@test "homepage: 服务卡片逐链接实访——全部可达且无 5xx/死链" {
    run gw_body home /api/services
    [ "$status" -eq 0 ]
    local hrefs h host path code n=0 bad=""
    hrefs=$(jq -r '[.[] | .services[]?] | map(.href) | map(select(length > 0)) | .[]' <<< "$output")
    [ -n "$hrefs" ]
    # 状态分类（探针 2026-11-14 实测：jenkins 403 / nexus,ldapadmin,home,auth 200 / dex 302）：
    #   200/301/302     匿名可达或正常跳转
    #   401/403         网关保护面，匿名被拒是预期
    #   404/000/5xx     死链、连接失败、服务错误——必须红
    while IFS= read -r h; do
        [ -n "$h" ] || continue
        host=$(python3 -c 'import sys, urllib.parse; print(urllib.parse.urlparse(sys.argv[1]).hostname or "")' "$h")
        path=$(python3 -c 'import sys, urllib.parse; u=urllib.parse.urlparse(sys.argv[1]); print(u.path or "/")' "$h")
        if [ -z "$host" ]; then
            bad="${bad}无法解析 host: ${h}\n"
            continue
        fi
        code=$(curl -sSk --connect-timeout 5 --max-time 20 \
            --resolve "${host}:${GW_HTTPS_PORT}:${GW_HOST}" \
            -o /dev/null -w '%{http_code}' "https://${host}:${GW_HTTPS_PORT}${path}") || code=000
        n=$((n + 1))
        echo "  ${code}  ${h}" >&2
        case "$code" in
            200|301|302|401|403) ;;
            *) bad="${bad}${code} ${h}\n" ;;
        esac
    done <<< "$hrefs"
    echo "实访 ${n} 个服务卡片链接" >&2
    [ "$n" -ge 5 ]
    if [ -n "$bad" ]; then
        echo "死链/错误响应：" >&2
        printf '%b' "$bad" >&2
        return 1
    fi
    # 书签（外链）：DinD 无外网不能实访，但格式必须完整——scheme 是 https 且有 host
    run gw_body home /api/bookmarks
    [ "$status" -eq 0 ]
    local ext scheme_host
    ext=$(jq -r '[.[] | .bookmarks[]?] | map(.href) | map(select(length > 0)) | .[]' <<< "$output")
    [ -n "$ext" ]
    while IFS= read -r h; do
        [ -n "$h" ] || continue
        scheme_host=$(python3 -c 'import sys, urllib.parse; u=urllib.parse.urlparse(sys.argv[1]); print(u.scheme, u.hostname or "")' "$h")
        if [[ "$scheme_host" != "https "* ]]; then
            echo "书签不是格式完整的 https URL: ${h}" >&2
            return 1
        fi
    done <<< "$ext"
}
