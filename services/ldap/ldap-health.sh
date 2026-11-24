#!/bin/sh
# 镜像内健康检查：ldapsearch base 探活（真叠加内容）
set -e
ldapsearch -x -H ldap://127.0.0.1 -b "${LDAP_BASE_DN:-dc=org-devops,dc=com}" -s base >/dev/null 2>&1
