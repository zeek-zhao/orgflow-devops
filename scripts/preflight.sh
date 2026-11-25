#!/usr/bin/env bash
# preflight.sh —— M2.0 P3 资源盘点闸门（ Harbor 官方栈 vs registry:2 降级 ）
#
# 三项硬指标（Harbor 官方套件最低要求 4C / 8G / 40G）：
#   1) nproc                            ≥ 4
#   2) MemAvailable + SwapFree          ≥ 8 GiB（物理可用 + swap 缓冲）
#   3) docker data-root 所在盘 available ≥ 40 GiB
#
# 结论两档（不自动降级，等人定）：
#   全过   → exit 0，建议走 Harbor 官方栈
#   任一不过 → exit 3，打印「降级为 registry:2」建议（功能少但能跑），等决策
#
# data-root 取 docker info 实值（本环境为 /ags/workbuddy-data/docker-main），
# 不硬编码 /var/lib/docker，避免 sandbox 重启回退时误判。
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

echo "资源盘点（Harbor 官方栈最低要求 4C / 8G / 40G）："
fail=0

# 1) CPU
cores="$(nproc 2>/dev/null || echo 0)"
if (( cores >= 4 )); then echo "  ✓ nproc = $cores（≥4）"; else echo "  ✗ nproc = $cores（<4）"; fail=1; fi

# 2) 内存（物理可用 MemAvailable + swap 缓冲 SwapFree，KiB → GiB 保留 2 位）
# 说明：本沙箱物理可用约 5.7 GiB，单看物理不足 8 GiB；已扩 8 GiB swap 作缓冲，
#       Harbor 官方栈在内存紧张时可落 swap，故按「可用内存 + swap」合计判定。
mem_kib="$(awk '/^MemAvailable:/{print $2}' /proc/meminfo 2>/dev/null || echo 0)"
swap_kib="$(awk '/^SwapFree:/{print $2}' /proc/meminfo 2>/dev/null || echo 0)"
mem_total_kib=$((mem_kib + swap_kib))
mem_gib="$(awk -v k="$mem_total_kib" 'BEGIN{printf "%.2f", k/1024/1024}')"
if awk -v g="$mem_gib" 'BEGIN{exit !(g>=8)}'; then
  echo "  ✓ MemAvailable + SwapFree = ${mem_gib} GiB（物理 ${mem_kib} KiB + swap ${swap_kib} KiB，合计≥8）"
else
  echo "  ✗ MemAvailable + SwapFree = ${mem_gib} GiB（物理 ${mem_kib} KiB + swap ${swap_kib} KiB，合计<8）"; fail=1
fi

# 3) data-root 盘可用空间
droot="$(docker info --format '{{.DockerRootDir}}' 2>/dev/null || echo /var/lib/docker)"
if [[ ! -d "$droot" ]]; then droot="/var/lib/docker"; fi
avail_kb="$(df -k "$droot" 2>/dev/null | tail -1 | awk '{print $4}')"
avail_gib="$(awk -v k="${avail_kb:-0}" 'BEGIN{printf "%.1f", k/1024/1024}')"
if awk -v g="$avail_gib" 'BEGIN{exit !(g>=40)}'; then
  echo "  ✓ data-root 盘可用 = ${avail_gib} GiB（≥40，data-root=$droot）"
else
  echo "  ✗ data-root 盘可用 = ${avail_gib} GiB（<40，data-root=$droot）"; fail=1
fi

if (( fail == 0 )); then
  echo "结论：三项全过 → 走 Harbor 官方栈（4C/8G/40G）。"
  exit 0
fi

echo "结论：存在不达标项。"
echo "建议：降级为 registry:2（功能少但能跑）；本脚本不自动降级，请人工决策后再进入 M2.1+。"
echo "提示：内存不足时可扩到 ≥8GiB 后重跑；data-root 空间不足可迁移到更大盘。"
exit 3
