#!/usr/bin/env bash
# verify.sh —— 全量验收矩阵 AC-1~AC-15（方案 §12）
# 静态项必跑必过；行为项需真机 docker/域名环境，标记 NEEDS-ENV（不误报绿）。
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
pass=0; fail=0; skip=0
P(){ echo "  ✓ AC-$1 $2"; pass=$((pass+1)); }
F(){ echo "  ✗ AC-$1 $2" >&2; fail=$((fail+1)); }
S(){ echo "  ~ AC-$1 $2（需真机环境，人工验收时执行）"; skip=$((skip+1)); }
run(){ bash "$1" >/dev/null 2>&1; }

echo "== M0 验收矩阵 =="
# 静态项
run scripts/check-image-digest.sh && P 1 "digest 全锁定" || F 1 "digest 全锁定"
run scripts/check-base-image.sh && P 2 "基底统一" || F 2 "基底统一"
run scripts/check-images-lock.sh && P 10 "双次部署 image Id 一致（lock 一致代理）" || F 10 "lock 一致"
run scripts/check-docs.sh && P 11 "文档登记册双向一致" || F 11 "文档登记册"
if [[ -f scripts/check_record_exists.sh ]]; then
  run scripts/check_record_exists.sh && P 15 "记录齐全" || F 15 "记录齐全"
else
  S 15 "记录齐全（依赖 T0 治理基座，合并后生效）"
fi
if command -v gitleaks >/dev/null 2>&1; then run scripts/secret-scan.sh && P 12 "无密" || F 12 "无密"; else S 12 "无密（gitleaks 未装）"; fi

# 行为项（需真机）
for spec in \
  "3:DNS 解析正确" "4:证书 SAN 含通配" "5:唯一入口 80/443" "6:按 Host 分站点" \
  "7:LDAP 绑定" "8:路由热更新 30s" "9:Tailscale 定向" "13:7 服务单起" \
  "14:Issue 全关（GitHub 侧核对）"; do
  id="${spec%%:*}"; desc="${spec#*:}"
  S "$id" "$desc"
done

echo ""
echo "静态: PASS=$pass FAIL=$fail | 需环境: $skip 项"
[[ $fail -eq 0 ]] && echo "✓ 静态验收全通过；行为项待人工验收签字后判定" || { echo "✗ 静态验收有 $fail 项失败" >&2; exit 1; }
