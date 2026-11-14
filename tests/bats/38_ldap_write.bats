#!/usr/bin/env bats
# #139 PR4 LDAP 写路径（BDD 场景见 tests/features/38_ldap_write.feature）。
# 目录是身份真源（A0/A1），能建号、能改组才谈得上运营。所有写入在本文件内
# 回滚（teardown + 幂等预清理），绝不污染 10_ldap 的「恰好 10 个用户」「uidNumber
# 全局唯一」基线断言。口令哈希用容器内 slappasswd 现场生成，明文不落盘。
setup() {
    load 'helpers/common'
    setup_gw
}

teardown() {
    # 无论用例成败，探测用户与组成员关系必须清除，恢复目录基线。
    compose_exec ldap sh -c 'exec ldapdelete -x -H ldap://localhost:389 \
        -D cn=admin,dc=devops,dc=com -w "$LDAP_ADMIN_PASSWORD" \
        "uid=bdd-probe-user,ou=users,dc=devops,dc=com" 2>/dev/null || true' sh >/dev/null 2>&1 || true
    compose_exec ldap sh -c 'exec ldapmodify -x -H ldap://localhost:389 \
        -D cn=admin,dc=devops,dc=com -w "$LDAP_ADMIN_PASSWORD" >/dev/null 2>&1 <<EOF
dn: cn=docs-users,ou=docs,ou=groups,dc=devops,dc=com
changetype: modify
delete: memberUid
memberUid: bdd-probe-user
EOF' sh >/dev/null 2>&1 || true
}

# 建探测用户：<口令> → 走 ldapadd 完整新建路径；uidNumber 取 49001，
# 远离 bootstrap 段（10_ldap 的全局唯一断言因此不受干扰）。
lw_uid_add() {
    local pass=$1 hash
    hash=$(compose_exec ldap sh -c 'exec slappasswd -h "{SSHA}" -s "$1"' sh "$pass") || return 1
    printf 'dn: uid=bdd-probe-user,ou=users,dc=devops,dc=com\nobjectClass: inetOrgPerson\nobjectClass: posixAccount\nuid: bdd-probe-user\ncn: BDD Probe User\nsn: Probe\nuidNumber: 49001\ngidNumber: 49001\nhomeDirectory: /home/bdd-probe-user\nuserPassword: %s\n' "$hash" \
        | compose_exec ldap sh -c 'exec ldapadd -x -H ldap://localhost:389 -D cn=admin,dc=devops,dc=com -w "$LDAP_ADMIN_PASSWORD"' sh
}

# 简化绑定探测：非 0 即失败（错误口令/条目不存在都走这条）
lw_bind() {
    compose_exec ldap sh -c 'exec ldapwhoami -x -H ldap://localhost:389 \
        -D "uid=bdd-probe-user,ou=users,dc=devops,dc=com" -w "$1"' sh "$1" >/dev/null 2>&1
}

@test "ldap: 写路径——建号(uidNumber+SSHA)→绑定成功→错口令拒绝→删除后绑定失败" {
    local pass="bdd-probe-pass-$(date +%s)"
    # 幂等预清理：上次运行残留先删，保证本次走完整新建路径
    compose_exec ldap sh -c 'exec ldapdelete -x -H ldap://localhost:389 \
        -D cn=admin,dc=devops,dc=com -w "$LDAP_ADMIN_PASSWORD" \
        "uid=bdd-probe-user,ou=users,dc=devops,dc=com" 2>/dev/null || true' sh >/dev/null 2>&1 || true
    run lw_uid_add "$pass"
    echo "ldapadd: $output" >&2
    [ "$status" -eq 0 ]
    # 正向：新账号的 SSHA 口令立即可用于绑定
    run lw_bind "$pass"
    [ "$status" -eq 0 ]
    # 反证：错口令必须被 INVALID_CREDENTIALS 拒绝，否则上一条是假绿
    run compose_exec ldap sh -c 'exec ldapwhoami -x -H ldap://localhost:389 \
        -D "uid=bdd-probe-user,ou=users,dc=devops,dc=com" -w "$1" 2>&1' \
        sh "deliberately-wrong-${pass:0:6}"
    [ "$status" -ne 0 ]
    assert_contains "$output" "Invalid credentials"
    # 删除后同一口令必须绑定失败（条目不存在也是 Invalid credentials）
    run compose_exec ldap sh -c 'exec ldapdelete -x -H ldap://localhost:389 \
        -D cn=admin,dc=devops,dc=com -w "$LDAP_ADMIN_PASSWORD" \
        "uid=bdd-probe-user,ou=users,dc=devops,dc=com"' sh
    [ "$status" -eq 0 ]
    run lw_bind "$pass"
    [ "$status" -ne 0 ]
}

@test "ldap: 写路径——组授权可运营:docs-users memberUid 增删即时生效" {
    local pass="bdd-probe-pass-$(date +%s)"
    compose_exec ldap sh -c 'exec ldapdelete -x -H ldap://localhost:389 \
        -D cn=admin,dc=devops,dc=com -w "$LDAP_ADMIN_PASSWORD" \
        "uid=bdd-probe-user,ou=users,dc=devops,dc=com" 2>/dev/null || true' sh >/dev/null 2>&1 || true
    run lw_uid_add "$pass"
    [ "$status" -eq 0 ]
    # 加组：memberUid 写入网关组授权的真源（A3 的 403 断言靠这张成员表成立）
    printf 'dn: cn=docs-users,ou=docs,ou=groups,dc=devops,dc=com\nchangetype: modify\nadd: memberUid\nmemberUid: bdd-probe-user\n' \
        | compose_exec ldap sh -c 'exec ldapmodify -x -H ldap://localhost:389 -D cn=admin,dc=devops,dc=com -w "$LDAP_ADMIN_PASSWORD"' sh
    run compose_exec ldap sh -c 'exec ldapsearch -x -H ldap://localhost:389 \
        -D cn=admin,dc=devops,dc=com -w "$LDAP_ADMIN_PASSWORD" \
        -b cn=docs-users,ou=docs,ou=groups,dc=devops,dc=com memberUid' sh
    [ "$status" -eq 0 ]
    assert_contains "$output" "memberUid: bdd-probe-user"
    # 移除后必须立即生效：授权真源写错了就是给不该进的人开门
    printf 'dn: cn=docs-users,ou=docs,ou=groups,dc=devops,dc=com\nchangetype: modify\ndelete: memberUid\nmemberUid: bdd-probe-user\n' \
        | compose_exec ldap sh -c 'exec ldapmodify -x -H ldap://localhost:389 -D cn=admin,dc=devops,dc=com -w "$LDAP_ADMIN_PASSWORD"' sh
    run compose_exec ldap sh -c 'exec ldapsearch -x -H ldap://localhost:389 \
        -D cn=admin,dc=devops,dc=com -w "$LDAP_ADMIN_PASSWORD" \
        -b cn=docs-users,ou=docs,ou=groups,dc=devops,dc=com memberUid' sh
    [ "$status" -eq 0 ]
    ! grep -q "memberUid: bdd-probe-user" <<< "$output"
}
