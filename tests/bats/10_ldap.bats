#!/usr/bin/env bats
setup() {
    load 'helpers/common'
    setup_gw
}

ldap_query() {
    compose_exec ldap sh -c 'exec ldapsearch -x -H ldap://localhost:389 -D cn=admin,dc=devops,dc=com -w "$LDAP_ADMIN_PASSWORD" -b dc=devops,dc=com "$@"' sh "$@"
}

@test "ldap: authenticated base, exactly 34 entries, admin mail and three OUs" {
    run ldap_query -s base
    [ "$status" -eq 0 ]
    run ldap_query -s sub '(objectClass=*)' dn
    [ "$status" -eq 0 ]
    [ "$(grep -c '^dn:' <<< "$output")" -eq 34 ]
    run ldap_query '(uid=admin.zeek)' mail
    [ "$status" -eq 0 ]
    assert_contains "$output" "uid=admin.zeek"
    grep -Eq '^mail: .+' <<< "$output"
    for ou in groups users departments; do
        run ldap_query "(ou=$ou)" dn
        [ "$status" -eq 0 ]
        assert_contains "$output" "dn: ou=$ou,dc=devops,dc=com"
    done
}

@test "ldap: uidNumber 全局唯一（#84 反 regression，曾出现 1009 重复）" {
    run ldap_query -s sub "(objectClass=posixAccount)" uidNumber
    [ "$status" -eq 0 ]
    local nums dup
    nums=$(grep -i "^uidNumber:" <<< "$output" | awk '{print $2}' | sort)
    [ -n "$nums" ]
    dup=$(uniq -d <<< "$nums")
    [ -z "$dup" ]
}

@test "ldap: 恰好 11 个用户条目（posixAccount，#84）" {
    run ldap_query -s sub "(objectClass=posixAccount)" dn
    [ "$status" -eq 0 ]
    [ "$(grep -c "^dn:" <<< "$output")" -eq 11 ]
}
