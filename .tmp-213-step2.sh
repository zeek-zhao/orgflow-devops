set -euo pipefail
cd "$HOME/workbuddy/orgflow-devops"

python3 - <<'PY'
import pathlib
p = pathlib.Path('.env')
lines = p.read_text().splitlines()
drop = {'GATEWAY_PORT', 'LDAPADMIN_PORT', 'ROUTER_PORT'}   # 已无任何代码引用
out, have = [], set()
for ln in lines:
    if '=' in ln and not ln.lstrip().startswith('#'):
        key = ln.split('=', 1)[0]
        if key in drop:
            continue
        have.add(key)
        if key == 'GATEWAY_DOMAIN':
            ln = 'GATEWAY_DOMAIN=org-devops.com'
        elif key == 'JENKINS_URL':
            ln = 'JENKINS_URL=https://jenkins.org-devops.com/'
    out.append(ln)
if 'GATEWAY_HTTP_PORT' not in have:
    i = next(n for n, l in enumerate(out) if l.startswith('GATEWAY_DOMAIN='))
    out[i + 1:i + 1] = ['GATEWAY_HTTP_PORT=80', 'GATEWAY_HTTPS_PORT=443']
p.write_text('\n'.join(out) + '\n')
print('写入完成')
PY

echo "=== 新 .env 键名（值脱敏，密钥只显示前 2 位）==="
sed -E 's/=(.{0,2}).*/=\1**/' .env
echo "=== 断言 ==="
grep -q '^GATEWAY_DOMAIN=org-devops.com$' .env && echo "✓ 域名已切"
grep -q '^GATEWAY_HTTPS_PORT=443$' .env && echo "✓ 端口已补"
grep -q '^JENKINS_URL=https://jenkins.org-devops.com/$' .env && echo "✓ JENKINS_URL 已改"
! grep -qE '^(GATEWAY_PORT|LDAPADMIN_PORT|ROUTER_PORT)=' .env && echo "✓ 死变量已清"
echo "密钥是否还在: $(grep -cE '^(JENKINS_ADMIN_PASSWORD|LDAP_ADMIN_PASSWORD|OAUTH2_CLIENT_SECRET|OAUTH2_COOKIE_SECRET|GITHUB_TOKEN)=..+' .env)/5"
