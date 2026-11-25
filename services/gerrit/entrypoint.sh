#!/usr/bin/env bash
# Gerrit entrypoint（文档 §M2.1）：启动前用 out/urls.env + defaults.env 渲染 gerrit.config，
# 避免字面域名/端口入库；先备份 .bak。渲染完 exec 官方镜像的原始 entrypoint。
set -euo pipefail

ROOT_CFG=/var/gerrit/etc
TMPL=/var/gerrit/etc/gerrit.config.tmpl
OUT_CFG=/var/gerrit/etc/gerrit.config
URLS_ENV=/etc/orgflow/urls.env

# 默认值（compose Environment 注入优先）；URL 只从 out/urls.env 取（公网 URL 单一真源）。
GERRIT_PUBLIC_URL="${GERRIT_PUBLIC_URL:-}"
P_GERRIT_HTTP="${P_GERRIT_HTTP:-8080}"
P_GERRIT_SSH="${P_GERRIT_SSH:-29418}"

if [[ -f "$URLS_ENV" ]]; then
  # shellcheck disable=SC1090
  source "$URLS_ENV"
  GERRIT_PUBLIC_URL="${URL_GERRIT:-$GERRIT_PUBLIC_URL}"
fi

if [[ -z "$GERRIT_PUBLIC_URL" ]]; then
  echo "FATAL: GERRIT_PUBLIC_URL 未注入且 $URLS_ENV 不可用" >&2
  exit 1
fi

# 备份现有配置（幂等：渲染失败可回滚）
[[ -f "$OUT_CFG" ]] && cp -f "$OUT_CFG" "${OUT_CFG}.bak"

export GERRIT_PUBLIC_URL P_GERRIT_HTTP P_GERRIT_SSH
# 模板里的 ${username}/${groupname} 是 Gerrit 运行时 LDAP 变量，必须原样保留。
# 官方 gerrit 镜像不保证带 gettext-base（envsubst），故优先 sed 定点替换这三个占位符，
# 不碰 ${username}/${groupname}；envsubst 白名单路径仅作兜底。
if sed -e "s|\${GERRIT_PUBLIC_URL}|$GERRIT_PUBLIC_URL|g" \
       -e "s|\${P_GERRIT_HTTP}|$P_GERRIT_HTTP|g" \
       -e "s|\${P_GERRIT_SSH}|$P_GERRIT_SSH|g" "$TMPL" > "$OUT_CFG"; then
  :
elif command -v envsubst >/dev/null 2>&1; then
  envsubst '${GERRIT_PUBLIC_URL} ${P_GERRIT_HTTP} ${P_GERRIT_SSH}' < "$TMPL" > "$OUT_CFG"
else
  echo "FATAL: 无法渲染 gerrit.config（sed 失败且无 envsubst）" >&2
  exit 1
fi

echo "Gerrit 配置已渲染：canonicalWebUrl=$GERRIT_PUBLIC_URL listenUrl=proxy-http://*:$P_GERRIT_HTTP"

# 官方 /entrypoint.sh 启动前会用 git config 覆盖 canonicalWebUrl（取 CANONICAL_WEB_URL，
# 缺省为 http://$HOSTNAME/）与 httpd.listenUrl（取 HTTPD_LISTEN_URL）。这里显式导出，
# 确保渲染出的公网 URL / 监听地址不被官方脚本改回容器内 hostname。
export CANONICAL_WEB_URL="$GERRIT_PUBLIC_URL"
export HTTPD_LISTEN_URL="proxy-http://*:$P_GERRIT_HTTP"

# 官方镜像原始 entrypoint（不同版本路径可能是 /docker-entrypoint.sh 或 /entrypoint.sh）
if [[ -f /docker-entrypoint.sh ]]; then
  exec /docker-entrypoint.sh "$@"
elif [[ -f /entrypoint.sh ]]; then
  exec /entrypoint.sh "$@"
fi
exec "$@"
