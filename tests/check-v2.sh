#!/usr/bin/env bash
# check-v2.sh —— §8 测试体系静态覆盖门禁（无 docker / 无 bats 可跑）
# 校验：15 个测试文件齐全、§8.3 关键断言存在、S_bats 已参数化（无硬编码 of-*）。
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
rc=0
ok(){ echo "  ✓ $1"; }
bad(){ echo "  ✗ $1" >&2; rc=1; }

# 1) 15 个测试文件齐全（7 S + 8 全栈）
need=(S_caddy S_certs-init S_dnsmasq S_homepage S_ldapadmin S_ldap S_router
      00_full_stack 10_dns 11_certs 12_caddy 13_ldap 14_ldapadmin 15_homepage 16_router)
for n in "${need[@]}"; do
  [[ -f "tests/bats/$n.bats" ]] && ok "$n.bats" || bad "缺 tests/bats/$n.bats"
done

# 2) 独立命名空间基础设施
[[ -f tests/v2.env ]] && grep -q 'orgflow-v2-net' tests/v2.env && ok "v2.env 独立网络" || bad "v2.env 缺 orgflow-v2-net"
[[ -f tests/run-v2.sh ]] && grep -q 'CONTAINER_PREFIX' tests/run-v2.sh && ok "run-v2.sh runner" || bad "run-v2.sh 缺 CONTAINER_PREFIX"

# 3) S_bats 参数化：不应再硬编码 of-<svc> 容器名（应写成 ${PFX:-of}-）
for n in "${need[@]:0:7}"; do
  f="tests/bats/$n.bats"
  if grep -qE "of-(caddy|certs-init|dnsmasq|homepage|ldapadmin|ldap|router)" "$f" 2>/dev/null; then
    # 允许注释里出现 of-，但不允许 docker 命令里出现
    if grep -qE '(inspect|exec|logs|start|wait)[^#]*of-' "$f"; then bad "$f 仍硬编码 of-* 容器"; fi
  fi
done

# 4) §8.3 关键断言覆盖（在测试体系中全局存在）
declare -A ASSERT=(
  ["无顶层compose"]='docker-compose.yml'
  ["dry-run顺序"]='--dry-run'
  ["单起ldap"]='--only ldap'
  ["公网根200"]='http_code'
  ["两分组名"]='局域网服务状态'
  ["favicon"]='favicon.ico'
  ["12卡"]='12'
  ["https-href"]='https://'
  ["dig应答"]='dig +short'
  ["ldapsearch"]='ldapsearch'
  ["digest一致"]='images.lock'
  ["零停机采样"]='零停机'
)
for k in "${!ASSERT[@]}"; do
  pat="${ASSERT[$k]}"
  if grep -rqF -- "$pat" tests/bats/*.bats; then ok "断言覆盖: $k"; else bad "断言未覆盖: $k"; fi
done

# 5) compose 容器名已参数化（默认 of，可覆盖 ofv2）
for svc in caddy certs-init dnsmasq homepage ldapadmin ldap router; do
  grep -q 'container_name: ${CONTAINER_PREFIX:-of}' "services/$svc/compose.yml" || bad "$svc compose 容器名未参数化"
done

# 6) up.sh 支持独立命名空间（PREFIX + ENV_FILE 可覆盖）
grep -q 'PREFIX="${CONTAINER_PREFIX:-of}"' up.sh && grep -q 'ENVFILE="${ENV_FILE' up.sh && ok "up.sh 支持独立命名空间" || bad "up.sh 未参数化前缀/env"

[[ $rc -eq 0 ]] && echo "✓ §8 测试体系静态覆盖通过（15 用例 + 命名空间基础设施）" || { echo "✗ §8 测试体系有缺口" >&2; exit 1; }
exit 0
