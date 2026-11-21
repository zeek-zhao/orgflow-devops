#!/usr/bin/env bash
# 60-verify-endpoints.sh —— 端点自检：把「服务起来了」和「能访问」分开验。
#
# 三层递进，每层失败时的排查方向完全不同：
#   第 1 层 容器内   ：服务进程自己认不认（healthz），不看网络
#   第 2 层 宿主机   ：映射端口通不通（由 docker inspect 拿实际 published 端口）
#   第 3 层 域名层   ：TLS + 路由 + 认证跳转对不对（带 SNI/Host 走 127.0.0.1）
#
# 判据纪律（见 docs/60-测试与运维/M0-测试体系.md）：
#   - 200 ≠ 能用：登录页是 200，内页未登录也是 403/302，别一律判 200；
#   - 「跳过」当红看：某层没跑就写「跳过」，等于这层不存在。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
# shellcheck source=lib/runtime.sh
. "$ROOT/scripts/lib/runtime.sh"
orgflow_load_runtime_env

HTTPS_PORT="${GATEWAY_HTTPS_PORT:-443}"
HTTP_PORT="${GATEWAY_HTTP_PORT:-80}"
DOMAIN="$GATEWAY_DOMAIN"
if [ "$HTTPS_PORT" = "443" ]; then VISIBLE_PORT=""; else VISIBLE_PORT=":$HTTPS_PORT"; fi

# URL 里**必须显式带端口**：--resolve 按 host:port 精确匹配，只写 https://host/
# 时 curl 按隐式 443 去连，映射对不上就退回真实 DNS —— 报出来是「连接失败」，
# 看着像网关没起来，实际是自检自己把地址写错了。
gw() {   # gw <子域> <路径> → HTTP 状态码
  curl -sSk --connect-timeout 5 --max-time 10 -o /dev/null -w '%{http_code}' \
    --resolve "$1.${DOMAIN}:${HTTPS_PORT}:127.0.0.1" \
    "https://$1.${DOMAIN}:${HTTPS_PORT}$2"
}

fails=0
check() {   # check <层> <描述> <期望|分隔> <实际>
  local layer="$1" label="$2" expected="$3" actual="$4"
  if [[ "|${expected}|" == *"|${actual}|"* ]]; then
    printf '  ✓ [%s] %s = %s（期望 %s）\n' "$layer" "$label" "$actual" "$expected"
  else
    # 失败逐项也走 stderr：只留汇总行的话，调用方只看到「失败 N 项」，不知道是哪项
    printf '  ✗ [%s] %s = %s（期望 %s）\n' "$layer" "$label" "$actual" "$expected" >&2
    fails=$((fails + 1))
  fi
}

echo "== 第 1 层：容器内自检 =="
while read -r name; do
  container="$(orgflow_container "$name")"
  id="$(docker ps -aq --filter "name=^${container}$" || true)"
  if [ -z "$id" ]; then
    printf '  ✗ [容器内] %s 容器 %s 不存在\n' "$name" "$container"
    fails=$((fails + 1))
    continue
  fi
  status="$(docker inspect -f '{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{else}}no-healthcheck{{end}}' "$id")"
  check "容器内" "$name 状态" "running healthy|running no-healthcheck" "$status"
done < <(orgflow_start_order)

echo "== 第 2 层：宿主机端口 =="
for mapping in "HTTP ${HTTP_PORT}" "HTTPS ${HTTPS_PORT}"; do
  read -r label port <<< "$mapping"
  code="$(curl -sS --connect-timeout 3 --max-time 5 -o /dev/null -w '%{http_code}' "http://127.0.0.1:${port}/" 2>/dev/null || echo 000)"
  # HTTP 端口对任意 Host 都是 308（跳 https）；用 -k 直接打 https 端口拿 200/308 都算通
  if [ "$code" = "000" ]; then
    printf '  ✗ [宿主机] %s 端口 %s 不可达\n' "$label" "$port" >&2
    fails=$((fails + 1))
  else
    printf '  ✓ [宿主机] %s 端口 %s 可连（%s）\n' "$label" "$port" "$code"
  fi
done

echo "== 第 3 层：域名层（TLS + 路由 + 认证） =="
# 期望值说明（#86 之后）：
#   jenkins /      → 403 或 302 都算「没给内容」；Jenkins 自 #86 起直连 LDAP 自带登录，
#                    匿名访问根路径由 Jenkins 自己回 403。旧值写死 302 会让任何正确的
#                    #86 环境必然红（2026-11-11 真机复现）。
#   jenkins /login → 200，这才是「反代通、应用活着、能登录」的正面判据。
#   docs /         → 302，唯一受网关保护的站点：未登录必跳到 auth 域
#   auth /ping     → 200
#   home /         → 200
#   ldapadmin /    → 200（登录页）
#   dex /dex/healthz → 200
# 期望值用 `|` 分隔表示「任一命中即通过」。
for check_spec in \
  "home / 200" \
  "jenkins /login 200" \
  "jenkins / 302|403" \
  "ldapadmin / 200" \
  "dex /dex/healthz 200" \
  "auth /ping 200" \
  "docs / 302"; do
  read -r sub path expected <<< "$check_spec"
  actual="$(gw "$sub" "$path")"
  if [ "$actual" = "000" ]; then
    printf '  ✗ [域名层] %s%s 连接失败（宿主端口 %s）\n' "$sub" "$path" "$HTTPS_PORT" >&2
    fails=$((fails + 1))
    continue
  fi
  check "域名层" "${sub}${path}" "$expected" "$actual"
done

# Nexus 不在 compose 里（#46）：未部署时 502 是**预期**，不能算失败。
nexus_code="$(gw nexus /)"
case "$nexus_code" in
  200) echo "  ✓ [域名层] nexus/ = 200（已由 job 部署）" ;;
  502|503|000) echo "  · [域名层] nexus/ = $nexus_code（#46：还没跑 nexus-deploy，属预期）" ;;
  *) check "域名层" "nexus/" "200|502|503" "$nexus_code" ;;
esac

echo
if [ "$fails" -gt 0 ]; then
  echo "✗ 端点自检失败 ${fails} 项" >&2
  exit 1
fi
echo "✓ 端点自检全部通过"
echo "  浏览器入口：https://home.${DOMAIN}${VISIBLE_PORT}/"
