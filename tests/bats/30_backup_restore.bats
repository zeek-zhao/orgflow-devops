#!/usr/bin/env bats
# 备份/恢复全链路（#64 复盘的延伸：backup.sh / restore.sh 此前只有
# test_backup.py 的假 docker 单测，真卷上从未跑过）。这里在 DinD 内层栈补齐：
#   1. 真卷备份：归档 + sha256 + meta 三件套齐全，--verify 复验通过
#   2. --dry-run 只出恢复计划，不停服、不碰卷
#   3. 备份 → 注入探测数据 → 恢复 → 探测数据消失、基线 33 条复原
#
# 取舍：
#   - 用 ldap 而不是 jenkins/nexus：卷最小、启停最快，且 bootstrap 数据有
#     已知确定基线（33 条，10_ldap 已断言），恢复结果可精确对照。
#   - BACKUP_DIR 一律指到 /tmp：out/ 是宿主共享 bind mount，往 out/backups
#     写测试归档会污染真机的备份目录。
#   - 两个脚本内部硬编码 `docker run … alpine`，但内层 daemon 只预灌 compose
#     锁定镜像。这里显式确保有真 alpine（restore 依赖 busybox sh 的
#     `set -o pipefail`，ubuntu 基座顶替会炸）——与被测代码同口径。
#   - 文件编号 30：restore 会 stop/start ldap，必须排在所有依赖
#     ldap 的用例（10_ldap）之后跑。

setup() {
    load 'helpers/common'
    setup_gw
}

# backup-common.sh 自己从 COMPOSE 字符串拼 compose 命令，
# 必须带上 harness 的 env 文件、override 与 project-directory
# （口径与 helpers/compose_cmd 一致，否则 stop/start 会打到错误的 compose 项目）。
backup_compose() {
    local args="docker compose -f $M0_REPO/docker-compose.yml"
    [[ -n ${M0_COMPOSE_EXTRA:-} ]] && args+=" -f $M0_COMPOSE_EXTRA"
    [[ -n ${M0_COMPOSE_OVERRIDE:-} ]] && args+=" -f $M0_COMPOSE_OVERRIDE"
    args+=" --project-directory $M0_REPO"
    printf '%s' "$args"
}

# 脚本硬编码 `docker run … alpine`（backup 的 tar、restore 的 find/pipefail——
# busybox sh 才支持 `set -o pipefail`，用 ubuntu 基座顶替会在 restore 里炸）。
# 与被测代码保持同口径：直接确保内层 daemon 有真 alpine。CI 可拉取；
# 离线机器按 harness 的规矩事先导入（Hub 来源默认离线导入）。
ensure_alpine() {
    docker image inspect alpine >/dev/null 2>&1 && return 0
    docker pull alpine >/dev/null 2>&1 || {
        echo "内层 daemon 缺 alpine（backup/restore 脚本硬编码引用）；CI 可拉取，离线机器需先导入" >&2
        return 1
    }
}

run_backup() {
    local dir=$1; shift
    ensure_alpine
    run env ENV_FILE="$M0_ENV_FILE" COMPOSE="$(backup_compose)" BACKUP_DIR="$dir" \
        bash "$M0_REPO/scripts/backup.sh" "$@"
}

run_restore() {
    local dir=$1; shift
    ensure_alpine
    run env ENV_FILE="$M0_ENV_FILE" COMPOSE="$(backup_compose)" BACKUP_DIR="$dir" \
        bash "$M0_REPO/scripts/restore.sh" "$@"
}

ldap_query() {
    compose_exec ldap sh -c 'exec ldapsearch -x -H ldap://localhost:389 -D cn=admin,dc=devops,dc=com -w "$LDAP_ADMIN_PASSWORD" -b dc=devops,dc=com "$@"' sh "$@"
}

# restore 后 ldap 被 compose start 拉起，slapd 需要几秒才能应答。
ldap_wait_ready() {
    local deadline=$((SECONDS + 60))
    until ldap_query -s base >/dev/null 2>&1; do
        (( SECONDS >= deadline )) && return 1
        sleep 2
    done
}

# compose start 立即返回，health 还在 starting；直接 assert_healthy 是竞态。
ldap_wait_healthy() {
    local id deadline=$((SECONDS + 120))
    id="$(compose_cmd ps -q ldap)" || return 1
    [ -n "$id" ] || return 1
    while :; do
        [ "$(docker inspect -f '{{.State.Health.Status}}' "$id")" = healthy ] && return 0
        (( SECONDS >= deadline )) && return 1
        sleep 3
    done
}

@test "backup: ldap 真卷备份产出三件套齐全的归档，--verify 复验通过" {
    local dir=/tmp/m0-backup-ldap
    rm -rf "$dir"; mkdir -p "$dir"

    run_backup "$dir" --service ldap
    [ "$status" -eq 0 ]
    assert_contains "$output" "备份 ldap (orgflow-devops_ldap_data)"
    assert_contains "$output" "完成"

    local archive
    archive="$(ls "$dir"/ldap-*.tgz)"
    [ -f "$archive" ]
    [ -f "${archive%.tgz}.sha256" ]
    [ -f "${archive%.tgz}.meta" ]

    # meta 必须写明服务与卷：restore 靠它拒绝「把 ldap 的包灌进 jenkins」。
    assert_contains "$(cat "${archive%.tgz}.meta")" "service=ldap"
    assert_contains "$(cat "${archive%.tgz}.meta")" "volume=orgflow-devops_ldap_data"

    # sha256 清单与归档实际内容一致（恢复前 verify_archive 会卡这道关）。
    [ "$(cut -d' ' -f1 "${archive%.tgz}.sha256")" = "$(sha256sum "$archive" | cut -d' ' -f1)" ]

    # 官方校验入口。
    run env ENV_FILE="$M0_ENV_FILE" bash "$M0_REPO/scripts/backup.sh" --verify "$archive"
    [ "$status" -eq 0 ]
    assert_contains "$output" "校验通过"

    # 备份脚本停过 ldap 又必须启回来，不启回就是静默把栈打残。
    ldap_wait_healthy
}

@test "restore: --dry-run 只出恢复计划，不停服不碰卷" {
    local archive
    archive="$(ls /tmp/m0-backup-ldap/ldap-*.tgz 2>/dev/null | head -1)"
    [ -n "$archive" ] || { echo "依赖 backup 用例产出的归档" >&2; return 1; }

    local started_before
    started_before="$(docker inspect -f '{{.State.StartedAt}}' of-ldap)"

    run_restore /tmp/m0-backup-ldap --service ldap --file "$archive" --dry-run --force
    [ "$status" -eq 0 ]
    assert_contains "$output" "恢复计划"
    assert_contains "$output" "dry-run：未停止服务、未修改卷"

    # StartedAt 不变 = 容器从未被重启；dry-run 停了服就是越权。
    [ "$(docker inspect -f '{{.State.StartedAt}}' of-ldap)" = "$started_before" ]
}

@test "restore: 注入探测数据后恢复，探测数据消失、基线回到 33 条" {
    local dir=/tmp/m0-backup-ldap
    local archive
    archive="$(ls "$dir"/ldap-*.tgz 2>/dev/null | head -1)"
    [ -n "$archive" ] || { echo "依赖 backup 用例产出的归档" >&2; return 1; }

    run ldap_query -s sub '(objectClass=*)' dn
    [ "$status" -eq 0 ]
    [ "$(grep -c '^dn:' <<< "$output")" -eq 34 ]

    # 备份之后注入一条探测数据：它不在归档里，恢复后必须消失——
    # 这才是「恢复真的回滚了数据」的证据，只对比条目数抓不住删错卷的错。
    local ldif='dn: uid=backup.probe,ou=users,dc=devops,dc=com
objectClass: inetOrgPerson
uid: backup.probe
cn: Backup Probe
sn: Probe'
    run compose_exec ldap sh -c 'printf "%s\n" "$1" | exec ldapadd -x -H ldap://localhost:389 -D cn=admin,dc=devops,dc=com -w "$LDAP_ADMIN_PASSWORD"' sh "$ldif"
    [ "$status" -eq 0 ]
    run ldap_query '(uid=backup.probe)' dn
    [ "$status" -eq 0 ]
    assert_contains "$output" "uid=backup.probe"

    run_restore "$dir" --service ldap --file "$archive" --force
    [ "$status" -eq 0 ]
    assert_contains "$output" "恢复完成: service=ldap"

    ldap_wait_healthy
    ldap_wait_ready

    run ldap_query -s sub '(objectClass=*)' dn
    [ "$status" -eq 0 ]
    [ "$(grep -c '^dn:' <<< "$output")" -eq 34 ]
    run ldap_query '(uid=backup.probe)' dn
    [ "$status" -eq 0 ]
    ! grep -q '^dn:' <<< "$output"
}
