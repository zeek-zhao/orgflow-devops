#!/usr/bin/env bash
# LDAP Admin Web：ldap 可达时跳转管理页；不可达时降级为登录页并重试（不崩）。
set -euo pipefail
LDAP_HOST="${LDAP_HOST:-ldap}"
BASE_DN="${BASE_DN:-dc=orgflow,dc=local}"
WEBROOT=/var/www/html
mkdir -p "$WEBROOT"

check_ldap() {
  # 用 python 裸 TCP 探测 389，不依赖 ldap-utils
  python3 - "$LDAP_HOST" <<'PY'
import socket, sys
try:
    s = socket.create_connection((sys.argv[1], 389), timeout=2); s.close()
    print("up")
except Exception:
    print("down")
PY
}

state="$(check_ldap)"
if [[ "$state" == "up" ]]; then
  echo "[ldapadmin] ldap 可达，进入管理页"
  echo "ok: ldap reachable ($BASE_DN)" > "$WEBROOT/index.html"
else
  echo "[ldapadmin] ldap 不可达，降级为登录页（持续重试）"
  cat > "$WEBROOT/index.html" <<EOF
<!doctype html><title>LDAP Admin - 等待目录</title>
<h1>LDAP Admin</h1>
<p>身份目录暂不可达，正在重试连接 $BASE_DN ...</p>
<form method="get"><input name="dn" placeholder="cn=admin,$BASE_DN"><button>登录</button></form>
EOF
fi
echo "[ldapadmin] 服务监听 :8080"
exec python3 -m http.server 8080 --directory "$WEBROOT"
