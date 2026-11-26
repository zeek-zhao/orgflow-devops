#!/usr/bin/env bash
# 功能级探测（M2.4 Phase3）——从 agent 容器执行（在 orgflow 网络，DNS 指向 dnsmasq）。
# 用法：verify-feature.sh <feature>   feature ∈ urls|cgit-smart-http|registry-auth|jenkins-theme|status-page
# 退出码即结果（0 成功，非 0 失败）；凭据经 env 注入（LDAP_BIND_PASSWORD / REGISTRY_CI_USER / REGISTRY_CI_PASSWORD），不进命令行。
set -uo pipefail
FEAT="${1:-}"
DEFAULTS_FILE="${DEFAULTS_FILE:-/opt/orgflow/config/defaults.env}"
need_env() {
  local k="$1" v="${!2:-}"
  if [[ -z "$v" && -r "$DEFAULTS_FILE" ]]; then v="$(sed -n "s/^$2=//p" "$DEFAULTS_FILE" | head -1)"; fi
  printf '%s' "$v"
}
PUBLIC_HOST="$(need_env PUBLIC_HOST PUBLIC_HOST)"
PUBLIC_PORT="$(need_env PUBLIC_PORT PUBLIC_PORT)"
[[ -n "$PUBLIC_HOST" ]] || PUBLIC_HOST="$(sed -n 's/^PUBLIC_HOST=//p' /opt/orgflow/config/defaults.env 2>/dev/null | head -1)"
PUBLIC_PORT="${PUBLIC_PORT:-18081}"
CADDY_IP="$(need_env CADDY_IP IP_CADDY)"; CADDY_IP="${CADDY_IP:-192.168.90.10}"

pass(){ echo "  ✓ $1"; }
fail(){ echo "  ✗ $1" >&2; exit 1; }

case "$FEAT" in
  urls)
    # 6 个公网入口状态码：Caddy 回环 + Host 头（Funnel 边缘 TLS 由 :8443 单独覆盖）。
    echo "[urls] 公网入口状态码（Caddy :$PUBLIC_PORT + Host: $PUBLIC_HOST）"
    rc=0
    for p in / /status /jenkins/login /cgit/ /ldapadmin/ /router/healthz; do
      code="$(curl -s -o /dev/null -w '%{http_code}' -m 6 -H "Host: $PUBLIC_HOST" "http://$CADDY_IP:$PUBLIC_PORT$p" 2>/dev/null)"
      echo "  $p -> $code"
      [[ "$code" =~ ^[23][0-9][0-9]$ ]] || { fail "$p 状态码 $code 非 2xx/3xx"; rc=1; }
    done
    # registry 鉴权生效：内网 registry:5000/v2/ 匿名应 401。
    # 说明：公网 Funnel 入口（FUNNEL_PORT_HARBOR）的 TLS 终止在宿主 Tailscale 边缘，
    # 从 agent 容器出发该公网链路不稳定（容器不共享宿主 Tailscale 路由，实测 000）；
    # 故公网入口可达性由外网单独验收，本探测在 orgflow 网络内用权威的内网端点判定鉴权状态。
    # 完整鉴权（匿名 401 + CI 用户 200）由 feat-registry-auth 单独覆盖。
    REG_HOST="$(need_env REGISTRY_HOST REGISTRY_HOST)"; REG_HOST="${REG_HOST:-registry}"
    REG_PORT="$(need_env REGISTRY_PORT REGISTRY_PORT)"; REG_PORT="${REG_PORT:-5000}"
    rcode="$(curl -s -o /dev/null -w '%{http_code}' -m 6 "http://$REG_HOST:$REG_PORT/v2/" 2>/dev/null)"
    echo "  registry 内网 http://$REG_HOST:$REG_PORT/v2/ -> $rcode"
    [[ "$rcode" == "401" ]] || { fail "registry 鉴权应 401，实为 $rcode"; rc=1; }
    [[ $rc -eq 0 ]] && pass "6 公网入口 + registry 401 全部符合"
    ;;
  cgit-smart-http)
    echo "[cgit-smart-http] info/refs 的 Content-Type"
    ct="$(curl -sI -m 6 "http://cgit:80/orgflow-devops.git/info/refs?service=git-upload-pack" 2>/dev/null | tr -d '\r' | grep -i '^content-type:' | head -1)"
    echo "  $ct"
    [[ "$ct" == *'application/x-git-upload-pack-advertisement'* ]] && pass "smart-http Content-Type 正确" || fail "Content-Type 非 git-upload-pack-advertisement"
    ;;
  registry-auth)
    echo "[registry-auth] 匿名 401 + CI 用户可拉 manifest"
    anon="$(curl -s -o /dev/null -w '%{http_code}' -m 6 "http://registry:5000/v2/" 2>/dev/null)"
    echo "  匿名 /v2/ -> $anon"
    [[ "$anon" == "401" ]] || fail "匿名应 401，实为 $anon"
    CU="${REGISTRY_CI_USER:-}"; CP="${REGISTRY_CI_PASSWORD:-}"
    [[ -n "$CU" && -n "$CP" ]] || fail "CI 凭据未注入"
    authed="$(curl -s -o /dev/null -w '%{http_code}' -m 6 -u "$CU:$CP" "http://registry:5000/v2/" 2>/dev/null)"
    echo "  CI 用户 /v2/ -> $authed"
    [[ "$authed" == "200" ]] && pass "鉴权生效且 CI 用户可访问" || fail "CI 用户应 200，实为 $authed"
    ;;
  jenkins-theme)
    echo "[jenkins-theme] 登录页深色主题标记"
    html="$(curl -s -m 8 "http://jenkins:8080/jenkins/login" 2>/dev/null)"
    echo "$html" | grep -q 'theme-manager-theme' || fail "缺 theme-manager-theme 标记"
    echo "$html" | grep -q '"id": "dark"' || fail "主题 id 非 dark"
    pass "theme-manager-theme id=dark 生效"
    ;;
  status-page)
    echo "[status-page] 状态页行数 == manifest 服务数"
    page="$(curl -s -m 8 "http://router:8080/status" 2>/dev/null)"
    rows="$(echo "$page" | grep -c '<tr>')"
    # 当前 manifest 13 服务 + 表头 1 = 14 行；服务数变化时应同步此断言与 checks.tsv。
    want=14
    echo "  <tr>=$rows (期望 $want = 13 服务 + 表头)"
    [[ "$rows" -eq "$want" ]] || fail "状态页行数不符: $rows != $want"
    # 每行链接非 /none（服务状态组 href 统一 /status）
    none="$(echo "$page" | grep -o 'href="/none"' | wc -l)"
    [[ "$none" -eq 0 ]] || fail "状态页含 $none 个 /none 死链"
    pass "状态页 $rows 行、无 /none 死链"
    ;;
  *)
    echo "用法：$0 <urls|cgit-smart-http|registry-auth|jenkins-theme|status-page>" >&2
    exit 2
    ;;
esac
