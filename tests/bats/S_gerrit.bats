#!/usr/bin/env bats
# S_gerrit —— Gerrit 代码评审服务（M2.1）
# 对应 tests/features/S-gerrit.feature。变量：PFX 容器前缀(默认 of)、
# GERRIT_PORT 公网端口(默认 8443)、PUBLIC_HOST 公网域名。
# 设计：只做容器可读断言 + 静态配置断言，不依赖 Jenkins/建仓等初始化项（属待办，不虚报）。

@test "容器 healthy" {
  run docker inspect -f '{{.State.Health.Status}}' "${PFX:-of}-gerrit"
  [ "$output" = "healthy" ]
}

@test "版本 3.9.x" {
  run docker exec "${PFX:-of}-gerrit" sh -c "java -jar /var/gerrit/bin/gerrit.war version 2>/dev/null"
  [[ "$output" == *3.9* ]]
}

@test "LDAP 认证类型生效（auth.type=LDAP）" {
  run docker exec "${PFX:-of}-gerrit" sh -c \
    "grep -E '^[[:space:]]*type[[:space:]]*=[[:space:]]*LDAP' /var/gerrit/etc/gerrit.config"
  [ "$status" -eq 0 ]
}

@test "LDAP 服务账号 bind（非匿名）+ supportAnonymous=false" {
  run docker exec "${PFX:-of}-gerrit" sh -c \
    "grep -E '^[[:space:]]*supportAnonymous[[:space:]]*=[[:space:]]*false' /var/gerrit/etc/gerrit.config && \
     grep -E '^[[:space:]]*username[[:space:]]*=' /var/gerrit/etc/gerrit.config"
  [ "$status" -eq 0 ]
}

@test "口令渲染无占位符残留" {
  run docker exec "${PFX:-of}-gerrit" sh -c \
    "grep -qE '\\\$\{GERRIT_PUBLIC_URL\}|\\\$\{LDAP_BIND_CREDENTIAL\}' /var/gerrit/etc/gerrit.config && echo LEFTOVER || echo CLEAN"
  [ "$output" = "CLEAN" ]
}

@test "[container] user = gerrit（非 gerrit2）" {
  run docker exec "${PFX:-of}-gerrit" sh -c \
    "awk '/^\[container\]/{f=1} f&&/user[[:space:]]*=/{print;exit}' /var/gerrit/etc/gerrit.config"
  [[ "$output" == *gerrit* && "$output" != *gerrit2* ]]
}

@test "accounts.visibility 收紧为 NONE（非 ALL）" {
  run docker exec "${PFX:-of}-gerrit" sh -c \
    "grep -E '^[[:space:]]*visibility[[:space:]]*=[[:space:]]*NONE' /var/gerrit/etc/gerrit.config"
  [ "$status" -eq 0 ]
}

@test "宿主 29418 已发布（tailnet 可达）" {
  run sh -c "ss -lnt 2>/dev/null | grep -E ':${GERRIT_PORT:-29418}[[:space:]]' || docker ps --format '{{.Ports}}' | grep -q '${GERRIT_PORT:-29418}'"
  [ "$status" -eq 0 ]
}
