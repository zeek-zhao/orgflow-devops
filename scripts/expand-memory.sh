#!/usr/bin/env bash
# expand-memory.sh —— M2.2 资源扩容固化（幂等，重启后手动跑一次）
#
# 背景：本沙箱 cgroup v1 内存上限默认 8 GiB，物理可用约 5.7 GiB，Harbor 官方栈
# （4C/8G/40G）按闸门判据需 ≥8 GiB。扩容由两部分组成：
#   1) cgroup 账面上限 8 GiB → 12 GiB（写 memory.limit_in_bytes，不重启、不动宿主）；
#   2) 8 GiB swapfile（放 docker data-root 所在盘 /ags，overlay 上的 swapfile 会被内核拒绝）。
# 两者都是运行时状态：沙箱/宿主重启后失效，需重新执行本脚本恢复。
#
# 纪律：
#   - 幂等：已达标则 skip，不重复 fallocate / swapon；
#   - 不删现有 swap、不改其它 cgroup 参数；
#   - 全程打印“前 → 后”，便于审计与回滚；
#   - 与 scripts/funnel-up.sh 同定位：恢复入口，不自动挂 cron/systemd（本沙箱无这俩）。
#
# 回滚：swapoff <SWAPFILE>；cgroup limit 写回 8589934592（8 GiB）。
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

CGROUP_LIMIT=/sys/fs/cgroup/memory/memory.limit_in_bytes
TARGET_LIMIT=$((12 * 1024 * 1024 * 1024))   # 12 GiB
SWAPFILE="${SWAPFILE:-/ags/workbuddy-data/swapfile}"
SWAP_SIZE="${SWAP_SIZE:-8G}"

echo "资源扩容固化（幂等）："
rc=0

# ---- 1) cgroup 内存上限 ----
if [[ ! -w "$CGROUP_LIMIT" ]]; then
  echo "  ✗ cgroup limit 不可写（$CGROUP_LIMIT）；跳过物理上限提升，仅依赖 swap"
  rc=1
else
  cur="$(cat "$CGROUP_LIMIT" 2>/dev/null || echo 0)"
  if (( cur >= TARGET_LIMIT )); then
    echo "  ✓ cgroup limit = $((cur/1024/1024/1024)) GiB（已 ≥12 GiB，skip）"
  else
    if echo "$TARGET_LIMIT" > "$CGROUP_LIMIT" 2>/dev/null; then
      echo "  ✓ cgroup limit: $((cur/1024/1024/1024)) GiB → $((TARGET_LIMIT/1024/1024/1024)) GiB"
    else
      echo "  ✗ cgroup limit 写入失败（当前 $((cur/1024/1024/1024)) GiB）"; rc=1
    fi
  fi
fi

# ---- 2) swapfile ----
swapped="$(awk '/^SwapTotal:/{print $2}' /proc/meminfo 2>/dev/null || echo 0)"
if (( swapped > 0 )); then
  echo "  ✓ swap 已启用：$(awk -v k="$swapped" 'BEGIN{printf "%.1f", k/1024/1024}') GiB（skip）"
else
  if [[ ! -f "$SWAPFILE" ]]; then
    d="$(dirname "$SWAPFILE")"
    if [[ ! -d "$d" ]]; then
      echo "  ✗ swapfile 父目录不存在：$d"; exit 1
    fi
    echo "  · 创建 swapfile：$SWAPFILE（$SWAP_SIZE）"
    fallocate -l "$SWAP_SIZE" "$SWAPFILE" || { echo "  ✗ fallocate 失败"; exit 1; }
    chmod 600 "$SWAPFILE"
    mkswap "$SWAPFILE" >/dev/null || { echo "  ✗ mkswap 失败"; exit 1; }
  fi
  if swapon "$SWAPFILE" 2>/dev/null; then
    echo "  ✓ swapon：$SWAPFILE（$(awk -v k="$(awk '/^SwapTotal:/{print $2}' /proc/meminfo)" 'BEGIN{printf "%.1f", k/1024/1024}') GiB）"
  else
    echo "  ✗ swapon 失败（$SWAPFILE）"; rc=1
  fi
fi

# ---- 汇总 ----
echo "  当前："
free -h | sed 's/^/    /'
exit "$rc"
