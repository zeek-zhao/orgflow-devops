#!/usr/bin/env bash
# Nexus 的部署脚本（#46）。
#
# ★ 为什么 Nexus 不在 docker-compose.yml 里：
#   它是「被 Jenkins 部署的制品库」，不是底座。放在 compose 里意味着
#   `make deploy` 之后它就位，但 job 侧永远得不到验证 —— 而 M0 的验收项之一
#   恰恰是「Nexus 由 Jenkins job 部署」。所以把它从 compose 摘出来，
#   由 job `nexus-deploy` 调这个脚本完成创建 + 改密。
#
# 谁在跑这个脚本：
#   - Jenkins job `nexus-deploy`（在 agent 上跑，agent 挂了宿主的 docker.sock）
#   - 测试 harness（等价于「跑完 job」之后的栈）
#   - 人手排查
#
# 幂等：容器已存在就复用，密码已改过就跳过。**绝不重建容器** ——
# 重建会换掉 /nexus-data 的挂载点归属，也可能把 nexus 的 blobstore 搞坏。
set -euo pipefail

CONTAINER="${NEXUS_CONTAINER:-of-nexus}"
IP="${NEXUS_IP:-172.31.0.21}"
# 与 tests/images.lock 的 nexus 行、mirror.yml 搬过来的包是同一份；
# test_jobs.py 会断言这里的 digest 与 images.lock 一致，别单独改。
IMAGE="${NEXUS_IMAGE:-ghcr.io/zeek-zhao/orgflow-devops/mirror-nexus:3.92.2@sha256:a32ae23e0fdacccc4f2a9cbf3aa613388d11a1495d5dd66c639c8e84ad39b179}"
ADMIN_ID="${NEXUS_ADMIN_ID:-admin}"
ADMIN_PASSWORD="${NEXUS_ADMIN_PASSWORD:-}"
READY_TIMEOUT="${NEXUS_READY_TIMEOUT:-300}"
POLL_INTERVAL="${NEXUS_POLL_INTERVAL:-3}"

log() { printf '[nexus-deploy] %s\n' "$*"; }
fail() { printf '[nexus-deploy] 失败: %s\n' "$*" >&2; exit 1; }

# ---- 网络与卷名 ----
#
# 两个名字都不是「猜」出来的，是 docker-compose.yml 里显式写死的：
#   - 网络：`networks.orgflow.name: orgflow`（不是默认的 <project>_orgflow）
#   - 项目名：`name: orgflow-devops` → 卷名 orgflow-devops_nexus_data
# 卷名还必须与 scripts/backup-common.sh 里写死的一致 —— 卷名一漂，
# 备份脚本会备份一个空卷而真正的数据在另一个卷里，**静默出错**，
# 等要恢复的时候才发现。bats 里直接断言容器的挂载源就是这个名字。
#
# ★ 只用 docker CLI，**不依赖 python3/jq**：这个脚本要在 Jenkins agent 上跑，
#   而 `jenkins/ssh-agent:jdk21` 是精简 Debian，没有 python3、没有 jq。
NETWORK="${NEXUS_NETWORK:-orgflow}"
VOLUME="${NEXUS_VOLUME:-orgflow-devops_nexus_data}"

docker network inspect "$NETWORK" >/dev/null 2>&1 \
    || fail "找不到网络 $NETWORK；先跑 make deploy（底座要先起来）"
log "网络 $NETWORK / 卷 $VOLUME / 固定 IP $IP"

# 网络存在但卷不存在时 docker 会自动建卷，这里显式建一次，
# 顺便让日志里能看到卷名（排查「数据去哪了」的第一个锚点）。
docker volume inspect "$VOLUME" >/dev/null 2>&1 || docker volume create "$VOLUME" >/dev/null

# ---- 容器 ----
#
# 有就复用。**不重建**：nexus 的 blobstore 在卷里，重建容器本身不丢数据，
# 但会丢掉 healthcheck 之外的一切运行时状态，而且没必要 —— 幂等的意思是
# 「跑一百遍和跑一遍一样」，不是「每次都重建一遍」。
if docker container inspect "$CONTAINER" >/dev/null 2>&1; then
    state="$(docker container inspect -f '{{.State.Status}}' "$CONTAINER")"
    log "容器 $CONTAINER 已存在（$state），复用"
    if [ "$state" != "running" ]; then
        docker start "$CONTAINER" >/dev/null
        log "已启动已有容器"
    fi
else
    log "创建容器 $CONTAINER"
    # --network-alias nexus：compose 里服务名会自动成为网络别名，docker run 不会。
    # Caddy 的上游写的是 `nexus:8081`，少了这个别名网关直接 502。
    docker run -d \
        --name "$CONTAINER" \
        --restart unless-stopped \
        --network "$NETWORK" \
        --network-alias nexus \
        --ip "$IP" \
        --label orgflow.managed-by=nexus-deploy \
        -v "$VOLUME:/nexus-data" \
        --health-cmd "curl -fsS http://localhost:8081/service/rest/v1/status || exit 1" \
        --health-interval 10s \
        --health-timeout 5s \
        --health-retries 30 \
        --health-start-period 120s \
        "$IMAGE" >/dev/null
fi

# ---- 等就绪 ----
#
# compose 的 healthcheck 只管「容器内部认为健康」，这里要的是 REST 真能用。
# 直接在容器里打 localhost，不绕网关：网关那条路还依赖 Caddy 的上游解析，
# 排查时分不清是 Nexus 没起还是路由没配对。
log "等待 REST API 就绪（最多 ${READY_TIMEOUT}s）"
deadline=$((SECONDS + READY_TIMEOUT))
until docker exec "$CONTAINER" curl -fsS http://localhost:8081/service/rest/v1/status >/dev/null 2>&1; do
    if (( SECONDS >= deadline )); then
        docker logs --tail=80 "$CONTAINER" >&2 || true
        fail "Nexus 在 ${READY_TIMEOUT}s 内没有就绪"
    fi
    sleep "$POLL_INTERVAL"
done
log "REST API 已就绪"

# ---- 改密 ----
#
# Nexus 首次启动会生成 /nexus-data/admin.password，里面是随机初始密码，
# 界面上会强制你改。但 M0 要的是「初始化时直接用配置的账号密码」——
# 所以这里用初始密码登录、改成 NEXUS_ADMIN_PASSWORD、再删掉初始密码文件。
#
# 幂等判断：先拿配置的密码试一次。能登录说明上次已经改过，直接跳过。
# 这样重跑 job 不会因为「初始密码文件已经删了」而红。
if [ -z "$ADMIN_PASSWORD" ]; then
    log "NEXUS_ADMIN_PASSWORD 未设置，跳过改密（Nexus 仍用初始密码，界面会强制改）"
else
    login_ok() {
        docker exec "$CONTAINER" curl -fsS -o /dev/null \
            -u "$ADMIN_ID:$1" "http://localhost:8081/service/rest/v1/security/users?userId=$ADMIN_ID" 2>/dev/null
    }

    if login_ok "$ADMIN_PASSWORD"; then
        log "配置的密码已生效，跳过改密"
    else
        initial="$(docker exec "$CONTAINER" cat /nexus-data/admin.password 2>/dev/null | tr -d '\r\n' || true)"
        [ -n "$initial" ] || fail "配置的密码登录失败，且 /nexus-data/admin.password 不存在 —— 密码已被改过但和 .env 不一致，请人工核对"

        log "用初始密码登录并改密（用户 $ADMIN_ID）"
        # JSON 转义手写：agent 上没有 python3/jq，不能靠它们拼 body。
        # 密码本身是 deploy.sh 生成的 hex，但允许人工改成含引号/反斜杠的串，
        # 所以还是按 JSON 规则转义一次。
        escaped="$(printf '%s' "$ADMIN_PASSWORD" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')"
        docker exec "$CONTAINER" curl -fsS -o /dev/null -X PUT \
            -u "$ADMIN_ID:$initial" \
            -H 'Content-Type: application/json' \
            -d "{\"password\":\"$escaped\"}" \
            "http://localhost:8081/service/rest/v1/security/users/$ADMIN_ID/change-password" \
            || fail "改密请求失败"

        # 删掉初始密码文件：留着它等于留一把随时能用的后门，
        # 而且它是「改密成功」的唯一可靠标记（界面上不再提示改密）。
        docker exec "$CONTAINER" rm -f /nexus-data/admin.password

        login_ok "$ADMIN_PASSWORD" || fail "改密后仍无法用新密码登录"
        log "改密完成，初始密码文件已删除"
    fi
fi

# ---- 最终确认 ----
docker exec "$CONTAINER" curl -fsS -o /dev/null http://localhost:8081/service/rest/v1/status \
    || fail "收尾自检失败：REST status 不可用"
log "完成：$CONTAINER @ $IP（卷 $VOLUME）"
