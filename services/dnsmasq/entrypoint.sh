#!/usr/bin/env bash
# =============================================================================
# dnsmasq 入口：把整个网关域名段解析到 Caddy 的固定 IP
#
#   GATEWAY_DOMAIN    网关域名后缀，默认 org-devops.com
#   GATEWAY_IP        Caddy 容器固定 IP，默认 172.31.0.10
#   DNSMASQ_LISTEN_IP 本容器要监听的地址，默认 172.31.0.2
#
# 为什么必须 bind-interfaces + listen-address：
#   Docker 在每个容器的 127.0.0.11:53 上跑了内嵌 DNS。dnsmasq 若绑 0.0.0.0:53
#   会与它端口冲突（EADDRINUSE），容器直接起不来。只绑自己的 eth0 地址即可，
#   客户端通过 compose 的 `dns: 172.31.0.2` 指过来，不受影响。
#
#   其余查询转发给 Docker 内嵌 DNS（127.0.0.11），
#   这样服务名（jenkins / dex …）依然能正常解析。
# =============================================================================
set -euo pipefail

DOMAIN="${GATEWAY_DOMAIN:-org-devops.com}"
GATEWAY_IP="${GATEWAY_IP:-172.31.0.10}"
LISTEN_IP="${DNSMASQ_LISTEN_IP:-}"
if [[ -z "$LISTEN_IP" ]]; then
    # 兜底：取本容器第一个非回环地址（固定 IP 网络下就是 172.31.0.2）
    LISTEN_IP="$(hostname -I 2>/dev/null | tr ' ' '\n' | grep -v '^$' | head -1 || true)"
fi
LISTEN_IP="${LISTEN_IP:-172.31.0.2}"

CONF=/etc/dnsmasq.d/orgflow.conf

cat > "$CONF" <<EOF
# 由 entrypoint.sh 生成，勿手改
domain-needed
bogus-priv
no-resolv
# 只绑自己的地址：0.0.0.0:53 会撞上 Docker 内嵌 DNS 的 127.0.0.11:53
listen-address=${LISTEN_IP}
bind-interfaces
# Docker 内嵌 DNS：其余域名（含服务名）继续走它
server=127.0.0.11
# *.${DOMAIN} 全部指向 Caddy
address=/.${DOMAIN}/${GATEWAY_IP}
log-queries
EOF

echo "[dnsmasq] listen ${LISTEN_IP}:53; *.${DOMAIN} -> ${GATEWAY_IP}"

exec dnsmasq --keep-in-foreground --log-facility=- \
    --conf-file=/etc/dnsmasq.conf --conf-dir=/etc/dnsmasq.d
