#!/usr/bin/env bash
# Caddy 入口：渲染 Caddyfile（按 Host 分站点 + :80→308），无证书时用 bootstrap 自签占位。
# 前置 certs-init 已把证书写入 /ca 卷；若卷为空则生成自签占位证书，仍能起（降级不崩）。
set -euo pipefail
DOMAIN="${DOMAIN:-org-devops.local}"
CA_DIR="${CA_DIR:-/ca}"
CONF="${CADDYFILE:-/etc/caddy/Caddyfile}"
CADDY_BIN="${CADDY_BIN:-caddy}"
SITES_MAP="${SITES_MAP:-/etc/caddy/sites.map}"

# 站点 → 后端映射（真源 config/routes.yaml 由 router 渲染覆盖；这里给 bootstrap 默认）
mkdir -p "$(dirname "$SITES_MAP")"
cat > "$SITES_MAP" <<EOF
home.$DOMAIN  home:3000
ldapadmin.$DOMAIN  ldapadmin:8080
router.$DOMAIN  router:8080
EOF

# 证书缺失时生成 bootstrap 自签占位（保证无 certs-init 也能起）
CRT="$CA_DIR/site.crt"; KEY="$CA_DIR/site.key"
if [[ ! -f "$CRT" || ! -f "$KEY" ]]; then
  mkdir -p "$CA_DIR"
  openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
    -subj "/CN=bootstrap" -keyout "$KEY" -out "$CRT" 2>/dev/null
  echo "[caddy] 证书缺失，已生成 bootstrap 自签占位"
fi

# 拼站点块
site_blocks=""
while read -r host backend; do
  [[ -z "$host" ]] && continue
  site_blocks+="
$host {
    tls $CRT $KEY
    reverse_proxy $backend
}
"
done < "$SITES_MAP"

cat > "$CONF" <<EOF
{
    admin 0.0.0.0:2019
}

# 唯一入口：:80 全量 308 跳 :443
:80 {
    redir https://{host}{uri} permanent
}
$site_blocks
EOF

echo "[caddy] 已渲染 $CONF"
exec "$CADDY_BIN" run --config "$CONF" --adapter caddyfile
