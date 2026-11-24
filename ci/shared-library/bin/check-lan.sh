#!/usr/bin/env bash
# 单服务局域网探测（M1，唯一真源）——从 agent 容器内执行（在 orgflow 网络、DNS 指向 dnsmasq）。
# 用法：check-lan.sh <service>     service ∈ dns|ldap|caddy|homepage|ldapadmin|router|jenkins|jenkins-agent
# 退出码即结果（0 成功，非 0 失败）；原始输出（含 dig/curl 退出码）打到 console，便于回看。
#
# 挂载即共享库：本脚本位于宿主 ci/shared-library/bin，挂进 agent /opt/orgflow/shared:ro。
# 宿主改完下一次构建立即生效，不重建容器、不拉 Git 库。Job 不得往 /opt/orgflow/shared 写文件。
set -uo pipefail

SVC="${1:-}"
# DOMAIN 由 Jenkinsfile/compose 从 ${DOMAIN} 注入（不写死业务网关域名，check-domain 门禁要求）
DOMAIN="${DOMAIN:?DOMAIN 未注入}"
DNS_IP="${IP_DNSMASQ:-192.168.90.15}"
LDAP_BASE="${LDAP_BASE:-dc=orgflow,dc=local}"
LDAP_DN="${LDAP_ADMIN_DN:-cn=admin,dc=orgflow,dc=local}"
LDAP_PW_FILE=""

cleanup() { [[ -n "$LDAP_PW_FILE" ]] && rm -f "$LDAP_PW_FILE"; }
trap cleanup EXIT

pass() { echo "  ✓ $1"; return 0; }
fail() { echo "  ✗ $1" >&2; return 1; }

case "$SVC" in
  dns)
    echo "[dns] dig home.$DOMAIN @$DNS_IP → 期望 192.168.90.10"
    out="$(dig +short "home.$DOMAIN" "@$DNS_IP" 2>&1)"; rc=$?
    echo "$out"; [[ $rc -eq 0 && "$out" == *"192.168.90.10"* ]] && pass dns || { fail "dns rc=$rc out=$out"; exit 1; }
    ;;
  ldap)
    echo "[ldap] ldapsearch -H ldap://ldap:389 -b $LDAP_BASE -s base"
    # osixia 默认可能拒绝匿名 bind：有口令就带凭据（-D/-y），否则 -x 匿名
    if [[ -n "${LDAP_BIND_PASSWORD:-}" ]]; then
      LDAP_PW_FILE="$(mktemp)"; printf '%s' "$LDAP_BIND_PASSWORD" > "$LDAP_PW_FILE"
      out="$(ldapsearch -x -H ldap://ldap:389 -D "$LDAP_DN" -y "$LDAP_PW_FILE" -b "$LDAP_BASE" -s base dn 2>&1)"; rc=$?
    else
      out="$(ldapsearch -x -H ldap://ldap:389 -b "$LDAP_BASE" -s base dn 2>&1)"; rc=$?
    fi
    echo "$out" | head -5; [[ $rc -eq 0 && "$out" == *"dn:"* ]] && pass ldap || { fail "ldap rc=$rc"; exit 1; }
    ;;
  caddy)
    echo "[caddy] curl http://caddy:2019/config/"
    code="$(curl -s -o /dev/null -w '%{http_code}' http://caddy:2019/config/)"; rc=$?
    [[ $rc -eq 0 && "$code" == "200" ]] && pass "caddy HTTP $code" || { fail "caddy rc=$rc code=$code"; exit 1; }
    ;;
  homepage)
    echo "[homepage] curl http://homepage:3000/"
    code="$(curl -s -o /dev/null -w '%{http_code}' http://homepage:3000/)"; rc=$?
    [[ $rc -eq 0 && "$code" == "200" ]] && pass "homepage HTTP $code" || { fail "homepage rc=$rc code=$code"; exit 1; }
    ;;
  ldapadmin)
    echo "[ldapadmin] curl http://ldapadmin:80/"
    code="$(curl -s -o /dev/null -w '%{http_code}' http://ldapadmin:80/)"; rc=$?
    [[ $rc -eq 0 && "$code" == "200" ]] && pass "ldapadmin HTTP $code" || { fail "ldapadmin rc=$rc code=$code"; exit 1; }
    ;;
  router)
    echo "[router] curl http://router:8080/healthz"
    body="$(curl -fsS http://router:8080/healthz 2>&1)"; rc=$?
    [[ $rc -eq 0 && "$body" == "ok" ]] && pass "router=$body" || { fail "router rc=$rc body=$body"; exit 1; }
    ;;
  jenkins)
    echo "[jenkins] curl http://jenkins:8080/jenkins/login"
    code="$(curl -s -o /dev/null -w '%{http_code}' http://jenkins:8080/jenkins/login)"; rc=$?
    [[ $rc -eq 0 && "$code" == "200" ]] && pass "jenkins HTTP $code" || { fail "jenkins rc=$rc code=$code"; exit 1; }
    ;;
  jenkins-agent)
    echo "[jenkins-agent] id + java -version + dig"
    id; /opt/java/openjdk/bin/java -version 2>&1 | head -1
    dig +short "home.$DOMAIN" "@$DNS_IP" | head -1
    pass jenkins-agent
    ;;
  *)
    echo "用法：$0 <dns|ldap|caddy|homepage|ldapadmin|router|jenkins|jenkins-agent>" >&2
    exit 2
    ;;
esac
