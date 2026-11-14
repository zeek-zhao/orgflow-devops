#!/usr/bin/env bats
# #139 PR4 Nexus 写路径（BDD 场景见 tests/features/39_nexus_write.feature）。
# B9 的 bats 面：pypi 走 REST 上传→匿名组仓索引→按索引 href 下载；docker 方向
# 断言 connector 匿名 401 / 凭据 200 的协议合同。镜像推拉由 nexus-deploy Job
# 在 agent 上承担（见 docs/requirements M0-B9），bats 不造镜像负载。
setup() {
    load 'helpers/common'
    setup_gw
}

nexus_admin_password() {
    local pw
    pw=$(sed -n 's/^NEXUS_ADMIN_PASSWORD=//p' "$M0_ENV_FILE" | tail -1)
    if [ -z "$pw" ]; then
        echo "✗ $M0_ENV_FILE 里没有 NEXUS_ADMIN_PASSWORD；无法做 Nexus 写断言" >&2
        return 1
    fi
    printf '%s' "$pw"
}

@test "nexus: pypi 写路径——REST 上传 wheel→匿名组仓索引→按索引下载 200" {
    local npass pkg ver whl up href url dl
    npass=$(nexus_admin_password) || return 1
    # 包名按运行时刻唯一：pypi hosted 资产没有 component 对象，REST 删不掉
    # （探针 2026-11-14 实证），唯一命名让每次运行自洽、不依赖上一次残留。
    pkg="bdd_probe_$(date +%s)"
    ver="0.1"
    whl="/tmp/${pkg}-${ver}-py3-none-any.whl"
    python3 - "$pkg" "$ver" "$whl" <<'PYWH'
import sys, zipfile
pkg, ver, path = sys.argv[1], sys.argv[2], sys.argv[3]
with zipfile.ZipFile(path, "w") as z:
    z.writestr(f"{pkg}/__init__.py", f"__version__ = {ver!r}\n")
    z.writestr(f"{pkg}-{ver}.dist-info/METADATA", f"Metadata-Version: 2.1\nName: {pkg}\nVersion: {ver}\nSummary: bdd probe\n")
    z.writestr(f"{pkg}-{ver}.dist-info/WHEEL", "Wheel-Version: 1.0\nRoot-Is-Purelib: true\nTag: py3-none-any\n")
    z.writestr(f"{pkg}-{ver}.dist-info/RECORD", "")
PYWH
    [ -s "$whl" ]
    up=$(gw_curl nexus "/service/rest/v1/components?repository=pypi-hosted" \
        -u "admin:${npass}" -F "pypi.asset=@${whl}" -o /dev/null -w '%{http_code}')
    echo "upload: $up" >&2
    [ "$up" = "204" ]
    # 消费面（B9）：匿名 pip 用户从组仓 simple 索引解析并下载——上传后立即可见
    run gw_curl nexus "/repository/pypi-group/simple/${pkg}/"
    [ "$status" -eq 0 ]
    assert_contains "$output" "${pkg}"
    href=$(printf '%s' "$output" | grep -o 'href="[^"]*"' | head -1 | sed 's/^href="//; s/"$//')
    [ -n "$href" ]
    # 索引 href 是相对路径（../../packages/...#sha256=...），urljoin 后才能下载
    url=$(python3 -c 'import sys, urllib.parse; print(urllib.parse.urljoin(sys.argv[1], sys.argv[2].split("#")[0]))' \
        "https://nexus.${GW_DOMAIN}/repository/pypi-group/simple/${pkg}/" "$href")
    dl=$(curl -sSk --connect-timeout 5 --max-time 30 \
        --resolve "nexus.${GW_DOMAIN}:${GW_HTTPS_PORT}:${GW_HOST}" \
        -o /dev/null -w '%{http_code} %{size_download}' "$url")
    echo "download: $dl ($url)" >&2
    [ "${dl%% *}" = "200" ]
    [ "${dl##* }" -ge 1 ]
}

@test "nexus: docker connector——匿名 401 质询，凭据后 catalog 200" {
    local npass anon authed
    npass=$(nexus_admin_password) || return 1
    # 匿名（无 Basic）：docker registry 协议必须回 401 质询，不能裸开
    anon=$(curl -sSk --connect-timeout 5 --max-time 20 \
        --resolve "docker.${GW_DOMAIN}:${GW_HTTPS_PORT}:${GW_HOST}" \
        -o /dev/null -w '%{http_code}' "https://docker.${GW_DOMAIN}:${GW_HTTPS_PORT}/v2/_catalog")
    echo "anon catalog: $anon" >&2
    [ "$anon" = "401" ]
    # 凭据后 catalog 必须可用：返回含 repositories 的 JSON（当前为空仓也合法）
    authed=$(curl -sSk --connect-timeout 5 --max-time 20 \
        --resolve "docker.${GW_DOMAIN}:${GW_HTTPS_PORT}:${GW_HOST}" \
        -u "admin:${npass}" "https://docker.${GW_DOMAIN}:${GW_HTTPS_PORT}/v2/_catalog")
    assert_contains "$authed" '"repositories"'
}
