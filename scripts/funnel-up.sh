#!/usr/bin/env bash
# funnel-up.sh —— 幂等恢复公网入口（Tailscale Funnel → Caddy :18081）
#
# 背景：Funnel 是进程级后台配置，tailscaled/机器重启后需重新下发。
# 本脚本可安全重复执行：若 Funnel 已指向目标端口则跳过，否则重建。
#
# 用法：
#   bash scripts/funnel-up.sh                    # 默认端口 18081
#   PORT=18081 bash scripts/funnel-up.sh
#
# 开机自启（任选其一，按环境支持情况）：
#   cron:     @reboot sleep 20 && bash /path/to/scripts/funnel-up.sh >>/var/log/funnel.log 2>&1
#   systemd:  见 docs/公网访问.md 的 funnel-up.service 示例
set -uo pipefail
PORT="${PORT:-${PUBLIC_PORT:-18081}}"
HOST_PORT="127.0.0.1:${PORT}"

echo "[funnel] 目标本地端口: $HOST_PORT"

# 是否已正确配置
current="$(tailscale funnel status 2>/dev/null | grep -oE 'http://127\.0\.0\.1:[0-9]+' | head -1)"
if [[ "$current" == "http://$HOST_PORT" ]]; then
  echo "[funnel] 已指向 $HOST_PORT，无需变更"
  exit 0
fi

# 重建（先关后开）
echo "[funnel] 重新下发 Funnel 配置..."
tailscale funnel --https=443 off >/dev/null 2>&1 || true
sleep 1
if tailscale funnel --bg --yes "$PORT" >/dev/null 2>&1; then
  echo "[funnel] ✓ 已启动，公网入口: https://$(tailscale status --json 2>/dev/null | python3 -c 'import sys,json;print(json.load(sys.stdin)["Self"]["DNSName"].rstrip("."))' 2>/dev/null)/"
  tailscale funnel status 2>/dev/null | grep -E 'proxy|ts.net' | head -3
else
  echo "[funnel] ✗ 启动失败（检查 tailscaled 在线与 funnel 授权）" >&2
  exit 1
fi
