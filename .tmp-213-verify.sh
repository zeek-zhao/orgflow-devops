set -uo pipefail
cd "$HOME/workbuddy/orgflow-devops"

D=$(grep '^GATEWAY_DOMAIN=' .env | cut -d= -f2)
HP=$(grep '^GATEWAY_HTTPS_PORT=' .env | cut -d= -f2)
PASS=0; FAIL=0

code() {  # code <host> <path>
  curl -sSk -o /dev/null -w '%{http_code}' --max-time 8 \
    --resolve "$1:${HP}:127.0.0.1" "https://$1:${HP}$2" 2>/dev/null || echo "conn-fail"
}
body() {  # body <host> <path>
  curl -sSk --max-time 8 --resolve "$1:${HP}:127.0.0.1" "https://$1:${HP}$2" 2>/dev/null
}
chk() {   # chk <描述> <期望> <实际>
  if [ "$3" = "$2" ]; then echo "  PASS  $1 = $3"; PASS=$((PASS+1))
  else echo "  FAIL  $1  期望[$2] 实际[$3]"; FAIL=$((FAIL+1)); fi
}

echo "== 域名 $D，宿主端口 $HP =="
echo
echo "-- 1. 站点可达性 --"
chk "jenkins / (未登录应 302 跳认证)" 302 "$(code "jenkins.$D" /)"
chk "auth /ping"                     200 "$(code "auth.$D" /ping)"
chk "home /"                         200 "$(code "home.$D" /)"
chk "nexus /"                        200 "$(code "nexus.$D" /)"
chk "ldapadmin / (已知无鉴权)"        200 "$(code "ldapadmin.$D" /)"
chk "dex 发现文档"                   200 "$(code "dex.$D" /dex/.well-known/openid-configuration)"

echo
echo "-- 2. 容器内 DNS（dnsmasq）--"
IP=$(docker exec of-caddy getent hosts "nexus.$D" 2>/dev/null | awk '{print $1}')
chk "caddy 解析 nexus.$D" "172.31.0.10" "${IP:-空}"

echo
echo "-- 3. 旧路径入口必须已消失 --"
OLD=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://127.0.0.1:8080/jenkins 2>/dev/null || echo "conn-fail")
if [ "$OLD" = "conn-fail" ] || [ "$OLD" = "000" ]; then
  echo "  PASS  8080/jenkins 已不存在（$OLD）"; PASS=$((PASS+1))
else
  echo "  FAIL  8080/jenkins 仍返回 $OLD"; FAIL=$((FAIL+1))
fi

echo
echo "-- 4. homepage 内容 --"
HOME_BODY=$(body "home.$D" /)
N=$(echo "$HOME_BODY" | grep -oE 'Jenkins|Nexus|LDAP Admin|Dex|Homepage' | sort -u | wc -l)
chk "页面出现的服务卡名种类" 5 "$N"
if echo "$HOME_BODY" | grep -q '{{HOMEPAGE_VAR_'; then
  echo "  FAIL  模板未展开（HOMEPAGE_VAR 残留）"; FAIL=$((FAIL+1))
else
  echo "  PASS  模板已展开"; PASS=$((PASS+1))
fi
if echo "$HOME_BODY" | grep -q "jenkins.$D"; then
  echo "  PASS  卡片链接指向 jenkins.$D"; PASS=$((PASS+1))
else
  echo "  FAIL  卡片链接里没有 jenkins.$D"; FAIL=$((FAIL+1))
fi

echo
echo "-- 5. TLS 证书 SAN --"
SAN=$(echo | openssl s_client -connect 127.0.0.1:${HP} -servername "jenkins.$D" 2>/dev/null \
      | openssl x509 -noout -ext subjectAltName 2>/dev/null | tr -d ' ')
if echo "$SAN" | grep -q "DNS:jenkins.$D"; then
  echo "  PASS  SAN 含 jenkins.$D"; PASS=$((PASS+1))
else
  echo "  FAIL  SAN 不含 jenkins.$D：$SAN"; FAIL=$((FAIL+1))
fi

echo
echo "-- 6. 容器健康 --"
docker ps --filter "name=of-" --format '{{.Names}}\t{{.Status}}' | sort
HEALTHY=$(docker ps --filter "name=of-" --filter "health=healthy" --format '{{.Names}}' | wc -l)
RUNNING=$(docker ps --filter "name=of-" --format '{{.Names}}' | wc -l)
chk "of-* 容器数" 10 "$RUNNING"
chk "healthy 数" 10 "$HEALTHY"

echo
echo "== 小结：PASS=$PASS FAIL=$FAIL =="
