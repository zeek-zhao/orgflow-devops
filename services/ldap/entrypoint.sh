#!/usr/bin/env bash
# OpenLDAP 入口：首次用 bootstrap LDIF 初始化目录（{SSHA} 口令 + ACL 匿名拒），前台运行。
set -euo pipefail
DOMAIN="${DOMAIN:-org-devops.local}"
BASE_DN="${BASE_DN:-dc=orgflow,dc=local}"
LDAP_PASSWORD="${LDAP_PASSWORD:-change-me}"
DATA=/var/lib/ldap
CONF=/etc/ldap/slapd.d

# 生成 {SSHA} 口令哈希（salt+sha1+base64）
hash="$(python3 - "$LDAP_PASSWORD" <<'PY'
import sys, hashlib, base64, os
pw = sys.argv[1].encode()
salt = os.urandom(8)
print('{SSHA}' + base64.b64encode(hashlib.sha1(pw + salt).digest() + salt).decode())
PY
)"

need_init=0
# 判断依据必须是"我们自己生成的 slapd.conf"，不能用 apt 预置的 slapd.d/cn=config
# （后者默认就存在，会导致跳过初始化，随后 -f slapd.conf 因文件不存在而启动失败）
[[ ! -f /etc/ldap/slapd.conf ]] && need_init=1

if [[ "$need_init" -eq 1 ]]; then
  echo "[ldap] 首次初始化目录 $BASE_DN"
  # 用 slapd 临时实例 + ldapadd 灌入 bootstrap LDIF
  sed "s|{{BASE_DN}}|$BASE_DN|g; s|{{HASH}}|$hash|g" /etc/ldap/bootstrap.ldif.tmpl > /tmp/bootstrap.ldif
  # 写 slapd 配置（数据库 + ACL：匿名拒，管理员可写）
  cat > /tmp/slapd.conf <<EOF
# 后端以动态模块提供，必须显式加载，否则 "Unrecognized database type (mdb)"
modulepath /usr/lib/ldap
moduleload back_mdb
include /etc/ldap/schema/core.schema
include /etc/ldap/schema/cosine.schema
include /etc/ldap/schema/inetorgperson.schema
pidfile /var/run/slapd/slapd.pid
argsfile /var/run/slapd/slapd.args
database mdb
maxsize 1073741824
suffix "$BASE_DN"
rootdn "cn=admin,$BASE_DN"
rootpw $hash
directory $DATA
# ACL：默认匿名无权限；管理员可写；认证用户可读
access to *
    by dn.base="cn=admin,$BASE_DN" write
    by users read
    by * none
EOF
  cp /tmp/slapd.conf /etc/ldap/slapd.conf
  mkdir -p "$DATA" /var/run/slapd
  chown -R openldap:openldap "$DATA" /var/run/slapd 2>/dev/null || true
  # -d 0 让临时实例前台运行：否则 slapd 会 daemonize，$! 拿到的是父进程，
  # kill 后真正持有 389 的子进程残留，导致下面的正式实例 "Address already in use"
  slapd -f /etc/ldap/slapd.conf -h "ldap://0.0.0.0:389/" -d 0 >/tmp/slapd-init.log 2>&1 &
  pid=$!
  sleep 1
  ldapadd -x -D "cn=admin,$BASE_DN" -w "$LDAP_PASSWORD" -f /tmp/bootstrap.ldif || true
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  # 等 389 端口释放（最多 10s），确保正式实例能绑定
  for i in $(seq 1 20); do
    python3 -c 'import socket;s=socket.socket();s.settimeout(0.3);exit(0 if s.connect_ex(("127.0.0.1",389))!=0 else 1)' && break
    sleep 0.5
  done
  echo "[ldap] 初始化完成"
fi

echo "[ldap] 启动 slapd"
exec slapd -f /etc/ldap/slapd.conf -h "ldap://0.0.0.0:389/" -d 0
