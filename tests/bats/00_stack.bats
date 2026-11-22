#!/usr/bin/env bats
setup() {
    load 'helpers/common'
    setup_gw
}

@test "stack: locked images, ten services and Ubuntu build bases" {
    local file="$M0_REPO/docker-compose.yml" image name ref digest expected
    # compose 按服务拆成片段后（M0 重构），根文件只剩 include: 与网络/卷，
    # 所以「哪些 image: 行」要从片段里收集，不能只 grep 根文件。
    # 上游/mirror 镜像共 6 个，必须逐条对得上 images.lock（jenkins 走 build:、
    # nexus 移出 compose 归 #46，都不在这里）。
    mapfile -t fragments < <(awk '/^[[:space:]]*-[[:space:]]+[A-Za-z0-9_.\/-]+\.ya?ml[[:space:]]*$/ {print $2}' "$file")
    [ "${#fragments[@]}" -eq 12 ]
    [ "$(grep -hcE '^[[:space:]]+image:' "$M0_REPO/docker-compose.yml" "${fragments[@]/#/$M0_REPO/}" \
             | awk '{n += $1} END {print n + 0}')" -eq 6 ]
    [ "$(grep -hcE '^[[:space:]]+image:.*@sha256:' "$M0_REPO/docker-compose.yml" "${fragments[@]/#/$M0_REPO/}" \
             | awk '{n += $1} END {print n + 0}')" -eq 6 ]
    while read -r image; do
        expected=
        while IFS=$'\t' read -r name ref digest; do
            [[ $name == \#* || -z $name ]] && continue
            if [[ ${image%@*} == "$ref" ]]; then expected="$ref@$digest"; fi
        done < "$M0_REPO/tests/images.lock"
        [ -n "$expected" ]
        [ "$image" = "$expected" ]
    done < <(grep -hE '^[[:space:]]+image:' "$M0_REPO/docker-compose.yml" "${fragments[@]/#/$M0_REPO/}" \
                 | awk '{print $2}' | sort -u)
    run compose_cmd config --services
    [ "$status" -eq 0 ]
    # M0 重构新增 docs（MkDocs 站点）→ 11 个服务；期望值对着 config/services.yml 数
    # 出来的服务数走，避免再出现「加一个服务要改三处断言」。
    local want
    want="$(python3 - "$M0_REPO" <<'PY'
import sys
sys.path.insert(0, sys.argv[1] + "/scripts")
import lib.config as cfg
print(len(cfg.load_services()["services"]))
PY
)"
    [ "$(printf '%s\n' "$output" | wc -l)" -eq "$want" ]
    for name in dnsmasq jenkins jenkins-agent caddy router ldap ldapadmin dex oauth2-proxy homepage docs; do
        printf '%s\n' "$output" | grep -qx "$name"
    done
    # #46：nexus 由 job `nexus-deploy` 用 docker run 拉起，不该再出现在 compose 里。
    # 反向断言比「删掉一行」重要 —— 哪天有人手滑加回去，这里立刻红。
    ! printf '%s\n' "$output" | grep -qx nexus
    expected=$(awk -F '\t' '$1 == "ubuntu" {print $2 "@" $3}' "$M0_REPO/tests/images.lock")
    for file in services/dnsmasq/Dockerfile services/router/Dockerfile \
                tools/jjb/Dockerfile tests/harness/Dockerfile; do
        [ "$(grep -c '^FROM ' "$M0_REPO/$file")" -eq 1 ]
        grep -Fx "FROM $expected" "$M0_REPO/$file"
        grep -Eq '^FROM ubuntu:24\.04@sha256:[a-f0-9]{64}$' "$M0_REPO/$file"
    done
    # jenkins 底座不是 ubuntu，进不了上面的 lock 循环，单独钉死：
    # 213 拉不到 Docker Hub，镜像只在 runner 上构建，底座漂了就等于 213 上行为漂了。
    [ "$(grep -c '^FROM ' "$M0_REPO/tools/jenkins/Dockerfile")" -eq 1 ]
    grep -Eq '^FROM jenkins/jenkins:lts-jdk21@sha256:[a-f0-9]{64}$' "$M0_REPO/tools/jenkins/Dockerfile"
}

@test "stack: every service on the orgflow network has a fixed IPv4" {
    local file="$M0_REPO/docker-compose.yml"
    # jjb 用 host 网络（要访问宿主上的网关入口），其余 11 个服务（含 M0 新增的 docs）全部固定 IP。
    # nexus 移出 compose 后它的固定 IP 由 scripts/70-nexus-deploy.sh 负责（172.31.0.21）。
    # M0 重构后 IP 不再写字面量：片段里是 ${IP_<SERVICE>}，真实值由
    # scripts/10-render-config.sh 渲染到 out/runtime.env，所以这里断言两件事 ——
    # ①片段里每个服务都声明了 ipv4_address 且值来自配置（不是写死的 172.31.0.x）；
    # ②渲染产物里每个 IP 互不相同且落在 subnet 内。
    mapfile -t fragments < <(awk '/^[[:space:]]*-[[:space:]]+[A-Za-z0-9_.\/-]+\.ya?ml[[:space:]]*$/ {print $2}' "$file")
    local want
    want="$(python3 - "$M0_REPO" <<'PY'
import sys
sys.path.insert(0, sys.argv[1] + "/scripts")
import lib.config as cfg
print(len(cfg.load_services()["services"]))
PY
)"
    [ "$(grep -hE '^[[:space:]]+ipv4_address:' "${fragments[@]/#/$M0_REPO/}" | wc -l)" -eq "$want" ]
    # 变量名里也可能有数字（IP_JENKINS_AGENT 之类不含，但 IP_OAUTH2_PROXY 含）——
    # 字符类必须写成 A-Z0-9_，只写 A-Z_ 会漏掉带数字的服务名，报出莫名其妙的差一。
    [ "$(grep -hE '^[[:space:]]+ipv4_address:[[:space:]]+\$\{IP_[A-Z0-9_]+\}' "${fragments[@]/#/$M0_REPO/}" | wc -l)" -eq "$want" ]
    ! grep -qE '^[[:space:]]+ipv4_address:[[:space:]]+172\.31\.0\.' "${fragments[@]/#/$M0_REPO/}"
    local subnet
    subnet=$(sed -n 's/^NETWORK_SUBNET="\{0,1\}\([^"[:space:]]*\)"\{0,1\}$/\1/p' "$M0_REPO/out/runtime.env")
    [ -n "$subnet" ]
    local count unique
    count=$(grep -cE '^IP_[A-Z_]+=' "$M0_REPO/out/runtime.env")
    [ "$count" -eq "$want" ]
    unique=$(grep -E '^IP_[A-Z_]+=' "$M0_REPO/out/runtime.env" \
                 | sed 's/^[^=]*="\{0,1\}\([^"]*\)"\{0,1\}$/\1/' | sort -u | wc -l)
    [ "$unique" -eq "$want" ]
    # 渲染出来的 IP 必须落在同一 /24 里（前 3 段相同）
    local prefix="${subnet%.[0-9]*}"
    [ "$(grep -E '^IP_[A-Z_]+=' "$M0_REPO/out/runtime.env" \
             | sed 's/^[^=]*="\{0,1\}\([^"]*\)"\{0,1\}$/\1/' | cut -d. -f1-3 | sort -u)" = "$prefix" ]
}
