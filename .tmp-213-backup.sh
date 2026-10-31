set -uo pipefail
cd "$HOME/workbuddy/orgflow-devops"

echo "== 备份 ldap =="
OUT=$(bash scripts/backup.sh --service ldap 2>&1)
RC=$?
echo "$OUT" | tail -6
echo "退出码=$RC"

TGZ=$(echo "$OUT" | grep -oE '/[^ ]*\.tgz' | tail -1)
if [ -z "$TGZ" ]; then TGZ=$(ls -t out/backups/ldap-*.tgz 2>/dev/null | head -1); fi
echo "产物: ${TGZ:-无}"
if [ -n "${TGZ:-}" ] && [ -f "$TGZ" ]; then
  echo "大小: $(du -h "$TGZ" | cut -f1)"
  echo "内含文件数: $(tar -tzf "$TGZ" | wc -l)"
  echo "前 5 项:"; tar -tzf "$TGZ" | head -5
else
  echo "!! 没产出 tgz"
fi

echo
echo "== 恢复演练（--dry-run，不停服）=="
STARTED_BEFORE=$(docker inspect -f '{{.State.StartedAt}}' of-ldap)
bash scripts/restore.sh --service ldap --file "$TGZ" --force --dry-run 2>&1 | tail -8
STARTED_AFTER=$(docker inspect -f '{{.State.StartedAt}}' of-ldap)
echo "ldap 是否被重启: $([ "$STARTED_BEFORE" = "$STARTED_AFTER" ] && echo 否 || echo 是)"

echo
echo "== 备份后 ldap 是否健康 =="
docker ps --filter name=of-ldap --format '{{.Names}} {{.Status}}'

echo
echo "== Jenkins API 能否穿过 oauth2（make jobs 的前提）=="
D=$(grep '^GATEWAY_DOMAIN=' .env | cut -d= -f2)
JURL=$(grep '^JENKINS_URL=' .env | cut -d= -f2)
echo "JENKINS_URL=$JURL"
curl -sSk -o /dev/null -w "  /api/json 未带凭据: %{http_code}\n" --max-time 8 --resolve "jenkins.$D:443:127.0.0.1" "https://jenkins.$D/api/json"
PW=$(grep '^JENKINS_ADMIN_PASSWORD=' .env | cut -d= -f2)
curl -sSk -o /dev/null -w "  /api/json 带 admin 基本认证: %{http_code}\n" --max-time 8 -u "admin:$PW" --resolve "jenkins.$D:443:127.0.0.1" "https://jenkins.$D/api/json"
echo "  （302/401 = oauth2 拦在前面；200 = API 可直连）"
