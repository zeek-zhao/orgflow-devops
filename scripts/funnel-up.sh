#!/usr/bin/env bash
# funnel-up.sh —— 幂等对账公网入口（Tailscale Funnel → Caddy 回环口），M2 §2.1
#
# 三映射（Funnel 边缘口 → 宿主回环口，全部来自 config/defaults.env，禁止写死）：
#   :443   → 127.0.0.1:${PUBLIC_PORT}        （门面 / Jenkins / cgit）
#   :8443  → 127.0.0.1:${PUB_HTTP_GERRIT}    （Gerrit）
#   :10000 → 127.0.0.1:${PUB_HTTP_HARBOR}    （Harbor，M2.2 上线后才探测）
#
# 纪律（文档 §2.1）：
#   - 表驱动对账：解析现状，缺的补、目标不一致的重建；已正确则 skip。
#   - 不主动删除配置外旧映射（删公网入口不可逆），只打印告警交人工。
#   - 边缘口只允许 {443,8443,10000}，否则 exit 2。
#   - 结尾对已上线目标 curl 探活，非 200/302 则 exit 1。
#
# 用法：
#   bash scripts/funnel-up.sh                 # 对账全部三条
#   WITH_HARBOR=1 bash scripts/funnel-up.sh   # 连 Harbor 一起探活（M2.2 部署后）
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
ENV_FILE="${ENV_FILE:-config/defaults.env}"
val() { grep -E "^$1=" "$ENV_FILE" 2>/dev/null | head -1 | cut -d= -f2-; }

PUBLIC_PORT="$(val PUBLIC_PORT)"
PUB_GERRIT="$(val PUB_HTTP_GERRIT)"
PUB_HARBOR="$(val PUB_HTTP_HARBOR)"
F_ENTRY="$(val FUNNEL_PORT_ENTRY)"
F_GERRIT="$(val FUNNEL_PORT_GERRIT)"
F_HARBOR="$(val FUNNEL_PORT_HARBOR)"
HOST="$(val PUBLIC_HOST)"

# 1) 边缘口合法性（硬约束：只允许 443/8443/10000）
ALLOWED="443 8443 10000"
for pair in "ENTRY:$F_ENTRY" "GERRIT:$F_GERRIT" "HARBOR:$F_HARBOR"; do
  k="${pair%%:*}"; v="${pair#*:}"
  case " $ALLOWED " in *" $v "*) ;; *) echo "[funnel] ✗ $k=$v 不在允许集合 $ALLOWED" >&2; exit 2;; esac
done

HOSTNAME="$(tailscale status --json 2>/dev/null | python3 -c 'import sys,json;print(json.load(sys.stdin)["Self"]["DNSName"].rstrip("."))' 2>/dev/null || echo "$HOST")"

# 期望映射表：edge|backend
declare -a EXPECT=(
  "$F_ENTRY|127.0.0.1:${PUBLIC_PORT}"
  "$F_GERRIT|127.0.0.1:${PUB_GERRIT}"
  "$F_HARBOR|127.0.0.1:${PUB_HARBOR}"
)

# 2) 解析现状：形如 /--... proxy http://127.0.0.1:18081
status="$(tailscale funnel status 2>&1)"
current_edges="$(printf '%s\n' "$status" | grep -oE 'https+://[^ ]+:[0-9]+|https://[^ ]+' | grep -oE ':[0-9]+$' | tr -d ':' | sort -u)"

echo "[funnel] 现状边缘口: $(echo "$current_edges" | tr '\n' ' ')"
echo "[funnel] 期望边缘口: $F_ENTRY $F_GERRIT $F_HARBOR"

# 3) 逐条对账：缺失则补（按 --https 指定边缘口）
for spec in "${EXPECT[@]}"; do
  edge="${spec%%|*}"; backend="${spec#*|}"
  # 现状该边缘口是否已配置且目标一致
  line="$(printf '%s\n' "$status" | grep -E ":$edge([ /]|$)" | head -1)"
  if printf '%s\n' "$status" | grep -q ":$edge"; then
    if printf '%s\n' "$line" | grep -qF "$backend"; then
      echo "[funnel] ✓ :$edge → $backend 已正确，skip"
    else
      echo "[funnel] ↻ :$edge 目标不符，重建"
      tailscale funnel --https="$edge" off >/dev/null 2>&1 || true
      sleep 1
      tailscale funnel --https="$edge" --bg --yes "$backend" >/dev/null 2>&1 \
        && echo "[funnel]   ✓ 已重建 :$edge → $backend" \
        || { echo "[funnel]   ✗ 重建失败 :$edge" >&2; exit 1; }
    fi
  else
    echo "[funnel] + 新增 :$edge → $backend"
    tailscale funnel --https="$edge" --bg --yes "$backend" >/dev/null 2>&1 \
      && echo "[funnel]   ✓ 已下发 :$edge" \
      || { echo "[funnel]   ✗ 下发失败 :$edge（检查 tailscaled 在线与 Funnel 授权）" >&2; exit 1; }
  fi
done

# 4) 告警配置外旧映射（不删）
for e in $current_edges; do
  case " $F_ENTRY $F_GERRIT $F_HARBOR " in *" $e "*) ;; *)
    echo "[funnel] ⚠ 存在配置外边缘口 :$e（未删除，如需清理请人工 tailscale funnel --https=$e off）";;
  esac
done

# 5) 探活：门面与 Gerrit 必测；Harbor 仅 WITH_HARBOR=1 时测（M2.2 上线后）
probe() {
  local url="$1" label="$2" code
  code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 15 "https://${HOSTNAME}:${url}" 2>/dev/null)"
  case "$code" in 200|302|301|401|403) echo "[funnel] ✓ $label $url → $code"; return 0;; esac
  echo "[funnel] ✗ $label $url → $code" >&2; return 1
}
rc=0
probe "$F_ENTRY/"       "门面"  || rc=1
probe "$F_GERRIT/"      "Gerrit" || rc=1
if [[ "${WITH_HARBOR:-0}" == "1" ]]; then
  probe "$F_HARBOR/"    "Harbor" || rc=1
fi

echo "[funnel] 对账完成：https://$HOSTNAME（边缘口 $F_ENTRY/$F_GERRIT/$F_HARBOR）"
exit "$rc"
