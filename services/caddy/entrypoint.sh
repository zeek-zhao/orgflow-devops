#!/usr/bin/env bash
# Caddy 入口：唯一 Web 入口，渲染两类站点：
#   1) 内网 TLS 站点（按 Host 分站点，内部 CA 自签）:80→308、:443 各 host
#   2) 公网入口站点 :PUBLIC_PORT（纯 HTTP）——TLS 由 Tailscale Funnel 在边缘终止，
#      Caddy 按 path 反代到各服务，供公网直接访问所有服务（状态页/健康/各服务）。
# 前置 certs-init 已把证书写入 /ca 卷；若卷为空则生成自签占位证书，仍能起（降级不崩）。
set -euo pipefail
DOMAIN="${DOMAIN:-org-devops.local}"
CA_DIR="${CA_DIR:-/ca}"
CONF="${CADDYFILE:-/etc/caddy/Caddyfile}"
CADDY_BIN="${CADDY_BIN:-caddy}"
SITES_MAP="${SITES_MAP:-/etc/caddy/sites.map}"
PUBLIC_PORT="${PUBLIC_PORT:-18081}"

# 站点 → 后端映射（真源 config/routes.yaml 由 router 渲染覆盖；这里给 bootstrap 默认）
# 注意：compose 服务名是 homepage（不是 home），DNAT 名写错会导致反代 502。
mkdir -p "$(dirname "$SITES_MAP")"
cat > "$SITES_MAP" <<EOF
home.$DOMAIN  homepage:3000
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

# 内网 TLS 站点块
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

# 内网唯一入口：:80 全量 308 跳 :443
:80 {
    redir https://{host}{uri} permanent
}
$site_blocks

# ===== 公网入口（Funnel → 本端口）=====
# TLS 在 Funnel 边缘终止并做合法 *.ts.net 证书，这里只做纯 HTTP 路由。
# 所有服务统一经此 Caddy 反代；健康与状态页也由 Caddy 提供。
:$PUBLIC_PORT {
    # 网关自身存活
    @healthz path /healthz
    handle @healthz {
        respond "ok" 200
    }

    # 服务总览页（列出各公网路径 + 内网实际后端，纯静态，无需探测）
    @root path /
    handle @root {
        respond <<HTML
<!doctype html><html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>OrgFlow DevOps · 服务总览</title>
<style>
body{font-family:system-ui,sans-serif;margin:0;background:#0d1117;color:#e6edf3}
.wrap{max-width:820px;margin:2.5rem auto;padding:0 1rem}
h1{font-size:1.5rem} .sub{color:#8b949e;margin-bottom:1.5rem}
a{display:block;padding:.7rem .9rem;margin:.4rem 0;background:#161b22;border:1px solid #30363d;
border-radius:8px;color:#58a6ff;text-decoration:none}
a:hover{border-color:#58a6ff} code{color:#8b949e;font-size:.85rem}
</style></head><body><div class="wrap">
<h1>OrgFlow DevOps · 最小底座服务总览</h1>
<div class="sub">公网入口经 Tailscale Funnel → Caddy 唯一入口 → 各服务。点下方链接直达。</div>
<a href="/home/"><b>统一导航面板</b> <code>/home/ → homepage:3000</code></a>
<a href="/ldapadmin/"><b>LDAP 管理页</b> <code>/ldapadmin/ → ldapadmin:8080</code></a>
<a href="/router/"><b>路由状态/热更新</b> <code>/router/ → router:8080</code></a>
<a href="/router/healthz"><b>Router 健康探针</b> <code>/router/healthz</code></a>
<a href="/caddy/"><b>Caddy Admin（只读查看）</b> <code>/caddy/ → caddy:2019</code></a>
<a href="/healthz"><b>入口存活探针</b> <code>/healthz</code></a>
<p class="sub">ldap(389)/dnsmasq(53udp) 为非 HTTP 内部服务，不提供公网 Web 路径。</p>
</div></body></html>
HTML
    }

    # 各服务反代（handle_path 去掉前缀后再转发）
    handle_path /home/* {
        reverse_proxy homepage:3000
    }
    handle_path /ldapadmin/* {
        reverse_proxy ldapadmin:8080
    }
    handle_path /router/* {
        reverse_proxy router:8080
    }
    handle_path /caddy/* {
        reverse_proxy localhost:2019
    }

    handle {
        respond "404 not found" 404
    }
}
EOF

echo "[caddy] 已渲染 $CONF（内网 TLS + 公网入口 :$PUBLIC_PORT）"
exec "$CADDY_BIN" run --config "$CONF" --adapter caddyfile
