#!/usr/bin/env bats
# 13_ldap —— LDAP 绑定（§8.3，独立命名空间 ofv2-ldap）

@test "ldap 容器 healthy" {
  run docker inspect -f '{{.State.Health.Status}}' "${PFX:-of}-ldap"
  [ "$output" = "healthy" ]
}

@test "ldapsearch 管理员绑定成功且用户数=2" {
  run docker exec -e PW="${LDAP_PW:-change-me}" "${PFX:-of}-ldap" sh -c \
    "ldapsearch -x -H ldap://127.0.0.1 -D ${LDAP_ADMIN:-cn=admin,dc=orgflow,dc=local} -w \$PW -b ${LDAP_BASE:-dc=orgflow,dc=local} '(objectClass=inetOrgPerson)' dn | grep -c '^dn:'"
  [ "$output" -ge 2 ]
}

@test "错口令被拒" {
  run docker exec "${PFX:-of}-ldap" sh -c \
    "ldapsearch -x -H ldap://127.0.0.1 -D ${LDAP_ADMIN:-cn=admin,dc=orgflow,dc=local} -w wrong-pass -b ${LDAP_BASE:-dc=orgflow,dc=local} >/dev/null 2>&1"
  [ "$status" -ne 0 ]
}
