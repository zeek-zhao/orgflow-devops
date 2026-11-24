#!/usr/bin/env bash
# verify.sh —— 全量验收矩阵 AC-1~AC-22（v1.0 §12）
# 静态项必跑必过；行为项需真机 docker/域名环境，标记 NEEDS-ENV（不误报绿）。
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
pass=0; fail=0; skip=0
P(){ echo "  ✓ AC-$1 $2"; pass=$((pass+1)); }
F(){ echo "  ✗ AC-$1 $2" >&2; fail=$((fail+1)); }
S(){ echo "  ~ AC-$1 $2（需真机环境，人工验收时执行）"; skip=$((skip+1)); }
run(){ bash "$@" >/dev/null 2>&1; }

echo "== M0 验收矩阵（v1.0 AC-1~22）=="
# ---- 静态项 ----
run scripts/check-images.sh --mode=digest && P 1 "digest 全锁定" || F 1 "digest 全锁定"
run scripts/check-images.sh --mode=upstream && P 2 "上游 digest 与登记表一致" || F 2 "上游 digest 登记表"
run scripts/check-images.sh --mode=base && P 2b "基底统一" || F 2b "基底统一"
run scripts/check-images.sh --mode=lock && P 10 "image Id 幂等（lock 一致代理）" || F 10 "lock 一致"
run scripts/check-docs.sh && P 11 "文档登记册双向一致" || F 11 "文档登记册"
run scripts/check-domain.sh && P 22 "域名配置化（无写死域名）" || F 22 "域名配置化"
if [[ -f scripts/check_record_exists.sh ]]; then
  run scripts/check_record_exists.sh && P 15 "记录齐全" || F 15 "记录齐全"
else
  S 15 "记录齐全（依赖 T0 治理基座）"
fi
if command -v gitleaks >/dev/null 2>&1; then run scripts/secret-scan.sh && P 12 "无密" || F 12 "无密"; else S 12 "无密（gitleaks 未装）"; fi

# AC-16 顺序可读：DRY_RUN up.sh 打印 7 步（静态：检查 manifest 完整 + 干跑步数）
steps=$(DRY_RUN=1 JSON=1 bash up.sh 2>/dev/null | grep -c '"service"' || true)
[[ "$steps" -ge 7 ]] && P 16 "顺序可读（DRY_RUN 打印 $steps 步）" || F 16 "顺序可读（仅 $steps 步）"

# AC-17 失败即停：未知服务应非零退出且打印失败信息
if bash up.sh __verify_nonexistent__ >/tmp/v17.out 2>&1; then F 17 "失败即停（未知服务却成功）"; else P 17 "失败即停（未知服务拒绝）"; fi

# AC-18 断网零裂图：图标全部 mdi-*（无外链图片）
if grep -rqE 'icon: https?://|icon: [a-z_]+\.(png|jpg|svg)' config/homepage/*.yaml; then F 18 "断网零裂图（发现外链图标）"; else P 18 "断网零裂图（全 mdi 图标）"; fi

# AC-20 独立构建：7 镜像的 Dockerfile + CI + 登记表齐全
built=0
for svc in dnsmasq caddy ldap ldapadmin homepage router; do [[ -f "services/$svc/Dockerfile" ]] && built=$((built+1)); done
[[ -f .github/workflows/build-images.yml && -f docs/运维/镜像与供应链.md && $built -eq 6 ]] \
  && P 20 "独立构建（$built Dockerfile+CI+登记表）" || F 20 "独立构建资产缺失"

# ---- 行为项（需真机）----
for spec in \
  "3:DNS 解析正确" "4:证书 SAN 含通配" "5:唯一入口 80/443" "6:按 Host 分站点" \
  "7:LDAP 绑定" "8:路由热更新 30s" "9:Tailscale 定向" "13:7 服务单起" \
  "14:Issue 全关（GitHub 侧核对）" "19:三张截图（人工确认）" \
  "21:公网三路径 P-1/P-2/P-3 全 200"; do
  id="${spec%%:*}"; desc="${spec#*:}"
  S "$id" "$desc"
done

echo ""
echo "静态: PASS=$pass FAIL=$fail | 需环境: $skip 项"
[[ $fail -eq 0 ]] && echo "✓ 静态验收全通过；行为项待人工验收签字后判定" || { echo "✗ 静态验收有 $fail 项失败" >&2; exit 1; }
