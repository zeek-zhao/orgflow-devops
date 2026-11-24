#!/usr/bin/env bash
# check-domain.sh —— 域名配置化门禁（v1.0 §6 / AC-22）
#
# 规则：配置文件（compose / yaml / Caddyfile / ldif / 运行脚本）不得写死"业务网关域名"
# 字面量。唯一真源是 .env 的 DOMAIN（= v1.0 的 GATEWAY_DOMAIN）。引用形式：
#   shell/compose 用 ${DOMAIN}；Caddyfile 用 {$DOMAIN}；homepage yaml 用 {{HOMEPAGE_VAR_GATEWAY_DOMAIN}}
#
# 判定范围（精确，避免误报）：只抓下列三类写死网关域名——
#   1) 形如 <label>.<内网后缀>  且后缀为 local / internal（如 home.org-devops.local）
#   2) 形如 <label>.ts.net      的 Tailscale 公网域名（如 xxx.tail123.ts.net）
#   3) 明确写死的 org-devops.<tld>
# 不误报：镜像仓库域（ghcr.nju.edu.cn/ghcr.io）、外部文档 URL、python 模块名（urllib.request）、
#   文件名（server.py / site.crt）、纯 IP。注释行与占位符片段不算。
# 白名单文件：.env.example / config/defaults.env（唯一默认值真源）、文档/测试/历史、本脚本自身。
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
rc=0

# 写死网关域名特征（大小写不敏感由 grep -i 处理）
GW_RE='([a-zA-Z0-9_-]+\.)+(local|internal|ts\.net|org-devops\.(local|com|net|cn))'

mapfile -t files < <(find . -type f \( \
    -name '*.yml' -o -name '*.yaml' -o -name 'Caddyfile' -o -name '*.ldif' \
    -o -name '*.sh' -o -name '*.py' -o -name '*.env' \) \
    -not -path './.git/*' \
    -not -path './docs/*' \
    -not -path './tests/*' \
    -not -path './services/*/build/*' \
    -not -path './out/*' \
    -not -name '.env.example' \
    -not -name 'check-domain.sh' \
    | sort)

for f in "${files[@]}"; do
  # defaults.env 是默认值真源，允许字面域名
  [[ "$f" == "./config/defaults.env" ]] && continue
  while IFS= read -r line; do
    [[ "$line" =~ ^[[:space:]]*(#|//) ]] && continue
    # LDAP 邮箱属性（xxx@domain）不是网关域名配置，放行
    [[ "$line" == *'@'* ]] && continue
    # 去掉占位符片段后再匹配（这些是合法的运行时注入，不是写死）
    stripped="$(echo "$line" | sed -E 's/\{\{[^}]*\}\}//g; s/\{\$[^}]*\}//g; s/\$\{[^}]*\}//g')"
    hit="$(echo "$stripped" | grep -ioE "$GW_RE" | head -1 || true)"
    [[ -z "$hit" ]] && continue
    echo "✗ $f 写死网关域名 '$hit': ${line:0:110}" >&2
    rc=1
  done < "$f"
done

# T6 路由单一真源：Caddyfile 只保留 admin 全局 + :80 跳转 + :PUBLIC_PORT 路径骨架，
# 不得再声明 <label>.{$DOMAIN...} 子域站点（否则与 routes.yaml 形成第二份路由真源）。
# 这类行用占位符写法，上面的 GW_RE 去占位符后抓不到，需单独断言。
SUBDOMAIN_VHOST_RE='^[[:space:]]*[a-zA-Z0-9_-]+\.\{\$DOMAIN'
sub_hits="$(grep -nE "$SUBDOMAIN_VHOST_RE" config/Caddyfile || true)"
if [[ -n "$sub_hits" ]]; then
  echo "✗ config/Caddyfile 仍含子域站点块（唯一真源=路径型 routes.yaml）：" >&2
  echo "$sub_hits" >&2
  rc=1
fi

[[ $rc -eq 0 ]] && echo "✓ 域名配置化：配置文件无写死网关域名，全部来自 \${DOMAIN}/占位符；Caddyfile 无子域 vhost（路径型单一真源）"
exit $rc
