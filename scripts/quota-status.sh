#!/usr/bin/env bash
# quota-status.sh —— 配额证据新鲜度与 timer 状态查看（m2.5.1 P0-1）
# 部署后、推代码前必跑：打印 systemd timer 状态（若可用）+ 门禁消费证据
# artifacts/quota/latest-of-builder.json 的 ts/age；age>10min 返回非 0（此时推 change 必被拦）。
# 退出码: 0=证据新鲜(≤10min)  1=过期/缺失/非法  3=systemd 不可用（仅提示，不影响证据判定）
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
Q="$ROOT/artifacts/quota/latest-of-builder.json"
MAX_MIN=10

echo "== OrgFlow 配额证据状态 =="
# systemd timer 状态（沙箱 PID1=supervisord 时不可用，仅提示，不影响证据判定）
if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
  systemctl status orgflow-quota.timer --no-pager -l 2>/dev/null | head -6 || echo "  (timer 未安装：make quota-install)"
  echo "  next: $(systemctl show orgflow-quota.timer -p NextElapseUSecRealtime --value 2>/dev/null || echo n/a)"
else
  echo "  ⚠ 当前 PID1 非 systemd：timer 不可用；真机请 make quota-install，或手动 make quota-guard 刷新"
fi

echo "  证据文件: $Q"
if [ ! -f "$Q" ]; then
  echo "  ✗ 证据缺失（container==of-builder 的门禁证据不存在）；先跑 make quota-guard"
  exit 1
fi
if command -v jq >/dev/null 2>&1; then
  ts="$(jq -r '.ts // empty' "$Q")"; verdict="$(jq -r '.verdict // empty' "$Q")"; container="$(jq -r '.container // empty' "$Q")"
else
  ts="$(python3 -c "import json;print(json.load(open('$Q')).get('ts',''))" 2>/dev/null)"
  verdict="$(python3 -c "import json;print(json.load(open('$Q')).get('verdict',''))" 2>/dev/null)"
  container="$(python3 -c "import json;print(json.load(open('$Q')).get('container',''))" 2>/dev/null)"
fi
[ -n "$ts" ] || { echo "  ✗ 证据 ts 缺失/JSON 非法"; exit 1; }

ets=$(date -u -d "$ts" +%s 2>/dev/null || echo 0)
now=$(date -u +%s)
if [ "$ets" -le 0 ]; then echo "  ✗ 证据 ts 非法: $ts"; exit 1; fi
age_sec=$(( now - ets )); age_min=$(( age_sec / 60 ))
echo "  ts=$ts  verdict=$verdict  container=$container  age=${age_min}min (阈值 ${MAX_MIN}min)"

rc=0
[ "$verdict" = "PASS" ] || { echo "  ✗ verdict 非 PASS: $verdict"; rc=1; }
[ "$container" = "of-builder" ] || { echo "  ✗ container 非 of-builder: $container"; rc=1; }
if [ "$age_min" -gt "$MAX_MIN" ]; then
  echo "  ✗ 证据过期 ${age_min}min > ${MAX_MIN}min：推 change 会被 Quota gate BLOCKED（刷新：make quota-guard / 等 timer）"
  rc=1
else
  [ "$rc" -eq 0 ] && echo "  ✓ 证据新鲜（age=${age_min}min ≤ ${MAX_MIN}min），可推代码"
fi
exit "$rc"
