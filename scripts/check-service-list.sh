#!/usr/bin/env bash
# check-service-list.sh —— 服务清单一致性门禁（r5 §4-2）
#
# 服务清单此前在 5 处各写一遍、靠人同步，已出现 verify-lan-all 描述写 7 项而实际 8 项的漂移。
# 本门禁以 services/manifest.tsv 的 service 列为唯一真源，派生两组并逐项比对：
#   A) 探测服务集 = manifest 全部 - certs-init（一次性任务） = 8 项；
#      核对 check-lan.sh 的 case 标签、check-lan-all.sh 的 ALL、verify-service.groovy 的 services 数组。
#      别名归一化：dns → dnsmasq。
#   B) M0 集合 = manifest 中 tag 含 m0 的项（6 常驻 + certs-init）= 7 项；
#      核对 check-v2.sh / run-v2.sh 中的 M0 服务循环列表。
# 不做运行时派生（Job DSL 读挂载文件失败会让 JCasC 起不来，风险高于收益）——只在门禁里静态比对。
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
rc=0

norm() { local x="$1"; [[ "$x" == dns ]] && echo dnsmasq || echo "$x"; }

# 真源：manifest 的 service 列（跳过表头）
ALL=$(awk -F'\t' 'NR>1 && $2!="" {print $2}' services/manifest.tsv | sort -u)
PROBE=$(echo "$ALL" | grep -v '^certs-init$' | sort -u)
# M0 真源：images.lock 中 tag 以 :v2 结尾的 service（6 常驻 + certs-init 复用 router）= 7 项
M0=$(awk -F'\t' 'NR>1 && $2 ~ /:v2$/ {print $1}' tests/images.lock | sort -u)

# 从各处提取服务 token（每行一个，排序归一）
case_lan=$(grep -oE '^  [a-z][a-z-]*(\|[a-z-]+)?\)' ci/shared-library/bin/check-lan.sh \
  | sed -E 's/^  //; s/\)$//' | cut -d'|' -f1 | while read -r x; do norm "$x"; done | sort -u)
all_lan=$(grep -oE '^ALL=\([^)]*\)' ci/shared-library/bin/check-lan-all.sh \
  | sed -E 's/^ALL=\(//; s/\)$//' | tr ' ' '\n' | while read -r x; do norm "$x"; done | sort -u)
groovy_svc=$(grep -oE "def services = \[[^]]*\]" config/jenkins/jobs/verify-service.groovy \
  | grep -oE "'[a-z-]+'" | tr -d "'" | sort -u)

compare() {
  local label="$1" want="$2" got="$3"
  if [[ "$want" == "$got" ]]; then
    echo "  ✓ $label（$(echo "$got" | wc -w) 项一致）"
  else
    echo "  ✗ $label 漂移" >&2
    echo "    真源: $(echo "$want" | tr '\n' ' ')" >&2
    echo "    实际: $(echo "$got" | tr '\n' ' ')" >&2
    rc=1
  fi
}

echo "服务清单一致性（真源 services/manifest.tsv）："
compare "check-lan.sh case" "$PROBE" "$case_lan"
compare "check-lan-all.sh ALL" "$PROBE" "$all_lan"
compare "verify-service.groovy 数组" "$PROBE" "$groovy_svc"

# B) M0 集合（6 常驻 + certs-init）：从 images.lock 的 v2 tag 行取 service
v2_env=$(grep -oE 'for svc in [a-z -]+; do' tests/check-v2.sh tests/run-v2.sh \
  | grep -oE 'in [a-z -]+;' | sed 's/in //; s/;//' | tr ' ' '\n' | grep -v '^$' | sort -u)
# check-v2.sh 第52行是 7 项循环，run-v2.sh 第46行也是 7 项；两者都应等于 M0
compare "check-v2.sh / run-v2.sh M0 循环" "$M0" "$v2_env"

if [[ $rc -eq 0 ]]; then echo "✓ 服务清单一致（探测 8 项 + M0 7 项）"; else echo "✗ 服务清单存在漂移" >&2; fi
exit $rc
