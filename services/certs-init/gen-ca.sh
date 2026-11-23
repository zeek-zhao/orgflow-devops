#!/usr/bin/env bash
# certs-init —— 内部 CA 与站点证书签发（幂等）
# 首次：生成自签 CA（10年）+ 站点证书（825天，SAN 含 *.DOMAIN 与各子域）到共享卷。
# 二次：证书存在且未过期则跳过。FORCE=1 才重签。
set -euo pipefail
DOMAIN="${DOMAIN:-org-devops.local}"
CA_DIR="${CA_DIR:-/ca}"
SITES="${SITES:-home ldapadmin auth router $DOMAIN}"
DAYS_CA=3650
DAYS_SITE=825

mkdir -p "$CA_DIR"
CA_KEY="$CA_DIR/ca.key"; CA_CRT="$CA_DIR/ca.crt"
SITE_KEY="$CA_DIR/site.key"; SITE_CRT="$CA_DIR/site.crt"

# 幂等：CA + 站点证书都存在且 CA 未过期则跳过
if [[ -f "$CA_CRT" && -f "$SITE_CRT" && "${FORCE:-0}" != "1" ]]; then
  if openssl x509 -in "$CA_CRT" -noout -checkend 0 >/dev/null 2>&1; then
    echo "[certs-init] 已存在且未过期，跳过（FORCE=1 强制重签）"
    exit 0
  fi
fi

echo "[certs-init] 生成内部 CA（$DAYS_CA 天）"
openssl genrsa -out "$CA_KEY" 2048 2>/dev/null
openssl req -x509 -new -nodes -key "$CA_KEY" -sha256 -days "$DAYS_CA" \
  -out "$CA_CRT" -subj "/CN=OrgFlow Internal CA/O=OrgFlow"

# 站点证书 SAN：各子域 + 通配 + apex
san="DNS:$DOMAIN,DNS:*.$DOMAIN"
for s in $SITES; do
  [[ "$s" == "$DOMAIN" ]] && continue
  san="$san,DNS:$s.$DOMAIN"
done
echo "[certs-init] 生成站点证书（$DAYS_SITE 天）SAN=$san"
openssl genrsa -out "$SITE_KEY" 2048 2>/dev/null
openssl req -new -key "$SITE_KEY" -out "$CA_DIR/site.csr" -subj "/CN=*.$DOMAIN"
cat > "$CA_DIR/site.ext" <<EOF
subjectAltName=$san
extendedKeyUsage=serverAuth
EOF
openssl x509 -req -in "$CA_DIR/site.csr" -CA "$CA_CRT" -CAkey "$CA_KEY" \
  -CAcreateserial -out "$SITE_CRT" -days "$DAYS_SITE" -sha256 \
  -extfile "$CA_DIR/site.ext" 2>/dev/null
echo "[certs-init] 完成：$CA_CRT + $SITE_CRT"
