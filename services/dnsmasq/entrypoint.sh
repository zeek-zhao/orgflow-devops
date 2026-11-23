#!/usr/bin/env bash
# dnsmasq 入口：按环境渲染配置，前台运行。
# 规则：*.<DOMAIN> → Caddy 固定 IP；未定义子域同样落 Caddy（通配）；其余 NXDOMAIN。
set -euo pipefail
DOMAIN="${DOMAIN:-org-devops.local}"
IP_CADDY="${IP_CADDY:-192.168.90.10}"
CONF=/etc/dnsmasq.d/orgflow.conf

cat > "$CONF" <<EOF
# 由 entrypoint 生成，勿手改
no-resolv
no-poll
listen-address=0.0.0.0
bind-interfaces
address=/.$DOMAIN/$IP_CADDY
# 本地上游（容器 DNS 自身用）
server=8.8.8.8
EOF
echo "[dnsmasq] 生成 $CONF: *.$DOMAIN → $IP_CADDY"
exec dnsmasq --no-daemon --conf-file=/etc/dnsmasq.conf --conf-file="$CONF"
