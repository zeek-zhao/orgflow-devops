set -uo pipefail
cd "$HOME/workbuddy/orgflow-devops"

D=$(grep '^GATEWAY_DOMAIN=' .env | cut -d= -f2)
HP=$(grep '^GATEWAY_HTTPS_PORT=' .env | cut -d= -f2)
code() { curl -sSk -o /dev/null -w '%{http_code}' --max-time 6 --resolve "$1:${HP}:127.0.0.1" "https://$1:${HP}$2" 2>/dev/null || echo "conn-fail"; }

cp config/routes.yaml /tmp/routes.yaml.bak
echo "== 基线 =="
echo "  jenkins=$(code "jenkins.$D" /)  nexus=$(code "nexus.$D" /)  tmpcheck=$(code "tmpcheck.$D" /)"

echo
echo "== 追加一条临时路由（模拟改 routes.yaml）=="
cat >> config/routes.yaml <<EOF

  - name: tmpcheck
    subdomain: tmpcheck
    upstream: nexus:8081
EOF
sleep 6
echo "  热加载后："
echo "  jenkins=$(code "jenkins.$D" /)  nexus=$(code "nexus.$D" /)  tmpcheck=$(code "tmpcheck.$D" /)"
echo "  Caddyfile 里是否已有 tmpcheck: $(grep -c 'tmpcheck' out/Caddyfile)"

echo
echo "== 回滚 =="
cp /tmp/routes.yaml.bak config/routes.yaml
sleep 6
echo "  回滚后："
echo "  jenkins=$(code "jenkins.$D" /)  nexus=$(code "nexus.$D" /)  tmpcheck=$(code "tmpcheck.$D" /)"
echo "  Caddyfile 里是否还有 tmpcheck: $(grep -c 'tmpcheck' out/Caddyfile)"
echo "  routes.yaml 是否与备份一致: $(cmp -s config/routes.yaml /tmp/routes.yaml.bak && echo yes || echo NO)"
echo "  站点数: $(grep -c '^https://' out/Caddyfile)"
