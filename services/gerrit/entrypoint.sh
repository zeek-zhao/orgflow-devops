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
# LDAP 服务账号口令（M0 ACL 匿名拒读，Gerrit 用 ldap.username/password 做查询 bind）。
# 与 Jenkins managerPasswordSecret 同源（LDAP_PASSWORD），仅运行时 env 注入，
# 渲染到卷内 gerrit.config（600/gerrit），不进 git 源码/文档。
LDAP_ADMIN_PASSWORD="${LDAP_ADMIN_PASSWORD:-}"
# Gerrit serverId 必须跨重启稳定（NoteDb change meta 里固化了创建时的 server id）。
# 优先用 env 注入值；否则读卷内持久化文件；再否则用与存量 NoteDb 一致的固定默认并落盘。
# 默认 UUID 来自本底座首次创建 Change 时的 server id（5593956a...），保证存量 change 可写。
SERVER_ID_FILE="$ROOT_CFG/server_id"
GERRIT_SERVER_ID="${GERRIT_SERVER_ID:-}"
if [[ -z "$GERRIT_SERVER_ID" && -s "$SERVER_ID_FILE" ]]; then
  GERRIT_SERVER_ID="$(cat "$SERVER_ID_FILE")"
fi
if [[ -z "$GERRIT_SERVER_ID" ]]; then
  GERRIT_SERVER_ID="5593956a-8275-4e5c-82ee-8fb6b2c067dd"
fi
printf '%s' "$GERRIT_SERVER_ID" > "$SERVER_ID_FILE"
chown gerrit:gerrit "$SERVER_ID_FILE" 2>/dev/null || true
chmod 600 "$SERVER_ID_FILE" 2>/dev/null || true

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

export GERRIT_PUBLIC_URL P_GERRIT_HTTP P_GERRIT_SSH GERRIT_SERVER_ID
# 模板里的 ${username}/${groupname} 是 Gerrit 运行时 LDAP 变量，必须原样保留。
# 用 python3 str.replace 做纯字面替换：口令含 | & \ / 等特殊字符时不会破坏配置
# （sed s|...| 会因 | 截断、& 展开成匹配串，清单风险项）。值经环境变量传入，
# 不经命令行参数，避免口令出现在 ps/argv。envsubst 白名单兜底同样只替换这 5 个占位符。
GERRIT_PUBLIC_URL="$GERRIT_PUBLIC_URL" P_GERRIT_HTTP="$P_GERRIT_HTTP" \
P_GERRIT_SSH="$P_GERRIT_SSH" LDAP_BIND_CREDENTIAL="$LDAP_ADMIN_PASSWORD" \
GERRIT_SERVER_ID="$GERRIT_SERVER_ID" \
python3 - "$TMPL" > "$OUT_CFG" <<'PYEOF'
import os, sys
src = open(sys.argv[1], encoding="utf-8").read()
# 只替换这 5 个已知占位符；${username}/${groupname} 等 Gerrit 运行时变量原样保留。
for key in ("GERRIT_PUBLIC_URL", "P_GERRIT_HTTP", "P_GERRIT_SSH", "LDAP_BIND_CREDENTIAL", "GERRIT_SERVER_ID"):
    src = src.replace("${" + key + "}", os.environ.get(key, ""))
sys.stdout.write(src)
PYEOF
RENDER_RC=$?
if [[ $RENDER_RC -ne 0 ]]; then
  echo "FATAL: python3 渲染 gerrit.config 失败（rc=$RENDER_RC）" >&2
  exit 1
fi
# 防止模板占位符未被替换（值缺失时 python 会替换为空串，这里校验公钥变量非空）
if grep -q '\${GERRIT_PUBLIC_URL}\|\${LDAP_BIND_CREDENTIAL}\|\${GERRIT_SERVER_ID}' "$OUT_CFG"; then
  echo "FATAL: gerrit.config 仍有未替换占位符" >&2
  exit 1
fi
# 明文口令只落在卷内 gerrit.config（600/gerrit），不进源码/文档；收紧权限并归主。
chown gerrit:gerrit "$OUT_CFG" 2>/dev/null || true
chmod 600 "$OUT_CFG" 2>/dev/null || true

echo "Gerrit 配置已渲染：canonicalWebUrl=$GERRIT_PUBLIC_URL listenUrl=proxy-http://*:$P_GERRIT_HTTP"

if [[ -z "$LDAP_ADMIN_PASSWORD" ]]; then
  echo "WARN: LDAP_ADMIN_PASSWORD 未注入，LDAP 查询 bind 将失败（M0 ACL 匿名拒读）" >&2
fi

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
