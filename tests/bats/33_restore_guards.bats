#!/usr/bin/env bats
# restore.sh 的安全闸门负向用例——30_backup_restore 只测了正路
# （备份→恢复→数据回来），守卫本身零覆盖。而守卫是「恢复操作销毁错误卷
# 的最后防线」，静默回归比没有恢复更危险。
#
# 六道闸门，全部在 restore.sh 的 stop_service 之前拒绝：
#   1. sha256 清单与归档不一致          （verify_archive）
#   2. meta 服务/卷与恢复目标不匹配     （meta 检查）
#   3. tar 条目路径穿越                 （python 检查）
#   4. 符号链接逃逸出归档根             （python 检查）
#   5. 设备节点条目                     （python 检查）
#   6. 目标卷非空且没给 --force         （check_empty）
#
# 每条都断言 of-ldap 的 StartedAt 不变：拒绝必须发生在「停服清卷」之前，
# 拒绝了却把服务停了，守卫就成了事故本身。

setup() {
    load 'helpers/common'
    setup_gw
}

# restore-common.sh 自己从 COMPOSE 字符串拼 compose 命令，
# 口径与 30_backup_restore 的 backup_compose 一致（带 env 文件与 override）。
restore_compose() {
    local args="docker compose -f $M0_REPO/docker-compose.yml"
    [[ -n ${M0_COMPOSE_EXTRA:-} ]] && args+=" -f $M0_COMPOSE_EXTRA"
    [[ -n ${M0_COMPOSE_OVERRIDE:-} ]] && args+=" -f $M0_COMPOSE_OVERRIDE"
    args+=" --project-directory $M0_REPO"
    printf '%s' "$args"
}

run_restore() {
    run env ENV_FILE="$M0_ENV_FILE" COMPOSE="$(restore_compose)" \
        BACKUP_DIR="$(mktemp -d)" \
        bash "$M0_REPO/scripts/restore.sh" "$@"
}

# 归档里放什么条目由 python3 定制（GNU tar -C 捏不出穿越路径）。
# kind: file / symlink / chardev
craft_tar() {
    local out=$1 kind=$2 name=$3 linkname=${4:-}
    python3 - "$out" "$kind" "$name" "$linkname" <<'PY'
import io, sys, tarfile
out, kind, name, linkname = sys.argv[1:5]
with tarfile.open(out, "w:gz") as t:
    info = tarfile.TarInfo(name)
    if kind == "file":
        data = b"restored-should-not-happen"
        info.size = len(data)
        t.addfile(info, io.BytesIO(data))
    elif kind == "symlink":
        info.type = tarfile.SYMTYPE
        info.linkname = linkname
        t.addfile(info)
    elif kind == "chardev":
        info.type = tarfile.CHRTYPE
        info.devmajor, info.devminor = 1, 3
        t.addfile(info)
    else:
        sys.exit("unknown kind: " + kind)
PY
}

# 合法归档 + 匹配的 sha256/meta（按 ldap 目标配齐，能一路走到 check_empty）。
craft_valid_ldap_archive() {
    local dir=$1 out="$1/ldap-valid.tgz" src
    src="$(mktemp -d)"
    mkdir -p "$src/data"
    echo baseline > "$src/data/base.conf"
    tar czf "$out" -C "$src" data
    rm -rf "$src"
    sha256sum "$out" > "${out%.tgz}.sha256"
    printf 'service=ldap\nvolume=orgflow-devops_ldap_data\n' > "${out%.tgz}.meta"
}

# 守卫的通用断言：拒绝 + 服务从未被停。
assert_refused_without_stopping() {
    local started_before=$1
    [ "$(docker inspect -f '{{.State.StartedAt}}' of-ldap)" = "$started_before" ]
    [ "$(docker inspect -f '{{.State.Running}}' of-ldap)" = "true" ]
}

@test "restore: sha256 清单与归档不一致必须被拒" {
    local dir
    dir="$(mktemp -d)"
    craft_valid_ldap_archive "$dir"
    # 改一个字节：清单对不上了。
    printf 'x' >> "$dir/ldap-valid.tgz"

    local started_before
    started_before="$(docker inspect -f '{{.State.StartedAt}}' of-ldap)"
    run_restore --service ldap --file "$dir/ldap-valid.tgz" --force

    [ "$status" -ne 0 ]
    assert_contains "$output" "sha256 校验失败"
    assert_refused_without_stopping "$started_before"
}

@test "restore: meta 服务/卷与恢复目标不匹配必须被拒" {
    local dir
    dir="$(mktemp -d)"
    craft_valid_ldap_archive "$dir"

    local started_before
    started_before="$(docker inspect -f '{{.State.StartedAt}}' of-ldap)"
    # 包是 ldap 的，目标却填 jenkins：把制品库数据灌进 LDAP 卷就是这么发生的。
    run_restore --service jenkins --file "$dir/ldap-valid.tgz" --force

    [ "$status" -ne 0 ]
    assert_contains "$output" "meta 服务/卷与恢复目标不匹配"
    assert_refused_without_stopping "$started_before"
}

@test "restore: 路径穿越条目必须被拒" {
    local dir
    dir="$(mktemp -d)"
    craft_tar "$dir/evil.tgz" file "data/../../escape.txt"

    local started_before
    started_before="$(docker inspect -f '{{.State.StartedAt}}' of-ldap)"
    run_restore --service ldap --file "$dir/evil.tgz" --force

    [ "$status" -ne 0 ]
    assert_contains "$output" "不安全的 tar 条目"
    assert_refused_without_stopping "$started_before"
}

@test "restore: 逃逸出归档根的符号链接必须被拒" {
    local dir
    dir="$(mktemp -d)"
    craft_tar "$dir/evil.tgz" symlink "data/link" "../../../outside"

    local started_before
    started_before="$(docker inspect -f '{{.State.StartedAt}}' of-ldap)"
    run_restore --service ldap --file "$dir/evil.tgz" --force

    [ "$status" -ne 0 ]
    assert_contains "$output" "不安全的 tar 链接"
    assert_refused_without_stopping "$started_before"
}

@test "restore: 设备节点条目必须被拒" {
    local dir
    dir="$(mktemp -d)"
    craft_tar "$dir/evil.tgz" chardev "data/console"

    local started_before
    started_before="$(docker inspect -f '{{.State.StartedAt}}' of-ldap)"
    run_restore --service ldap --file "$dir/evil.tgz" --force

    [ "$status" -ne 0 ]
    assert_contains "$output" "不安全的 tar 条目"
    assert_refused_without_stopping "$started_before"
}

@test "restore: 目标卷非空且未给 --force 必须被拒" {
    local dir
    dir="$(mktemp -d)"
    craft_valid_ldap_archive "$dir"

    local started_before
    started_before="$(docker inspect -f '{{.State.StartedAt}}' of-ldap)"
    # ldap 卷被 bootstrap 灌过数据，非空；故意不给 --force。
    run_restore --service ldap --file "$dir/ldap-valid.tgz"

    [ "$status" -ne 0 ]
    assert_contains "$output" "目标卷非空"
    assert_refused_without_stopping "$started_before"
}
