#!/usr/bin/env bash
# gen-hosts.sh —— 生成域名 hosts 片段（域名 → Caddy IP）
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
DOMAIN="$(grep -E '^DOMAIN=' config/defaults.env | cut -d= -f2)"
IP="$(grep -E '^IP_CADDY=' config/defaults.env | cut -d= -f2)"
echo "# orgflow-minimal 域名解析片段（加入客户端 /etc/hosts）"
for s in home ldapadmin auth router; do
  echo "$IP  $s.$DOMAIN"
done
