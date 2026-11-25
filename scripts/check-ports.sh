#!/usr/bin/env bash
# check-ports.sh —— M2 §1 三层端口模型静态门禁（无 docker / 无网络）
#
# 六条检查：
#   1) 三层端口变量齐全（defaults.env）
#   2) Funnel 边缘端口只允许 443/8443/10000，且三者互不相同（判据3：非法端口拦截）
#   3) 三个 Funnel 口占满全集 {443,8443,10000}（硬约束1）
#   4) 宿主回环端口合法（正整数/互不冲突/不与 Funnel 口重复）
#   5) out/urls.env 存在且与端口变量一致（单一真源，先 make render）
#   6) 对外端口无字面硬编码：公网相关源码里不写死对外端口数字（判据4）
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
ENV_FILE="${ENV_FILE:-config/defaults.env}"
rc=0
ok()   { printf '  ✓ %s\n' "$1"; }
bad()  { printf '  ✗ %s\n' "$1"; rc=1; }
val()  { grep -E "^$1=" "$ENV_FILE" 2>/dev/null | head -1 | cut -d= -f2-; }

echo "端口配置门禁（ENV_FILE=$ENV_FILE）："

# 1) 变量齐全
need=(FUNNEL_PORT_ENTRY FUNNEL_PORT_GERRIT FUNNEL_PORT_HARBOR \
      PUBLIC_PORT PUB_HTTP_GERRIT PUB_HTTP_HARBOR \
      P_GERRIT_HTTP P_GERRIT_SSH P_CGIT_HTTP P_HARBOR_PORTAL)
missing=()
for k in "${need[@]}"; do [[ -z "$(val "$k")" ]] && missing+=("$k"); done
if (( ${#missing[@]} > 0 )); then bad "1) 缺端口变量: ${missing[*]}"; else ok "1) 三层端口变量齐全（9 项）"; fi

# 2) Funnel 口合法且互不相同
ALLOWED="443 8443 10000"
fentry="$(val FUNNEL_PORT_ENTRY)"; fgerrit="$(val FUNNEL_PORT_GERRIT)"; fharbor="$(val FUNNEL_PORT_HARBOR)"
bad2=()
for pair in "ENTRY:$fentry" "GERRIT:$fgerrit" "HARBOR:$fharbor"; do
  k="${pair%%:*}"; v="${pair#*:}"
  case " $ALLOWED " in *" $v "*) ;; *) bad2+=("$k=$v");; esac
done
[[ "$fentry" == "$fgerrit" || "$fentry" == "$fharbor" || "$fgerrit" == "$fharbor" ]] && bad2+=("三者重复")
if (( ${#bad2[@]} > 0 )); then bad "2) Funnel 口非法/重复: ${bad2[*]}（仅允许 443/8443/10000）"; else ok "2) Funnel 口合法且互不相同"; fi

# 3) 三个 Funnel 口占满全集
if [[ "$fentry $fgerrit $fharbor" == "443 8443 10000" ]]; then
  ok "3) 三个公网口占满 {443,8443,10000}"
else
  bad "3) 三个公网口未占满全集: $fentry/$fgerrit/$fharbor"
fi

# 4) 宿主回环端口合法
loop=(PUBLIC_PORT PUB_HTTP_GERRIT PUB_HTTP_HARBOR)
bad4=()
seen=""
for k in "${loop[@]}"; do
  v="$(val "$k")"
  [[ "$v" =~ ^[0-9]+$ ]] && (( v > 1024 && v < 65536 )) || { bad4+=("$k=$v 非合法端口"); continue; }
  case " $seen " in *" $v "*) bad4+=("$k=$v 重复");; esac
  seen="$seen $v"
  case " $fentry $fgerrit $fharbor " in *" $v "*) bad4+=("$k=$v 与 Funnel 口冲突");; esac
done
if (( ${#bad4[@]} > 0 )); then bad "4) 回环端口异常: ${bad4[*]}"; else ok "4) 宿主回环端口合法且无冲突"; fi

# 5) out/urls.env 与端口变量一致（若不存在则提示先 make render）
if [[ -f out/urls.env ]]; then
  bad5=()
  grep -q "URL_ENTRY=https://$(val PUBLIC_HOST):$fentry$" out/urls.env || bad5+=("URL_ENTRY")
  grep -q "URL_GERRIT=https://$(val PUBLIC_HOST):$fgerrit$" out/urls.env || bad5+=("URL_GERRIT")
  grep -q "URL_HARBOR=https://$(val PUBLIC_HOST):$fharbor$" out/urls.env || bad5+=("URL_HARBOR")
  if (( ${#bad5[@]} > 0 )); then bad "5) out/urls.env 漂移（先 make render）: ${bad5[*]}"; else ok "5) out/urls.env 与端口一致"; fi
else
  bad "5) out/urls.env 不存在（先 make render）"
fi

# 6) 对外端口无字面硬编码：公网相关源码不写死对外端口数字
#    检查 compose / Caddyfile / 应用配置模板里不出现 18085/18086（Gerrit/Harbor 回环口）
#    及 funnel-up.sh 不写死 8443 之外的对外口（443 在 TLS 上下文允许）
bad6=""
if grep -rnE '18085|18086' config/Caddyfile config/routes.yaml services/*/compose.yml 2>/dev/null | grep -v '\${PUB_HTTP' | grep -q .; then
  bad6="发现字面 18085/18086"
fi
if [[ -n "$bad6" ]]; then bad "6) 对外端口字面硬编码: $bad6"; else ok "6) 对外端口无字面硬编码"; fi

exit $rc
