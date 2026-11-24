#!/usr/bin/env bash
# run-v2.sh —— 独立命名空间测试 runner（M0-v2 §8.0 零停机纪律）
# 所有容器 ofv2-*、网络 orgflow-v2-net、卷 orgflow-v2-*、192.168.91.0/24、端口偏移。
# 绝不 stop/restart/down 线上 of-*；线上断言只做只读 curl。
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
V2ENV="tests/v2.env"
PREFIX="ofv2"

# 从 v2.env 读关键值（避免 source 污染 / 也便于 bash -n）
val() { grep -E "^$1=" "$V2ENV" | head -1 | cut -d= -f2-; }
NET="$(val ORG_NETWORK)"
SUBNET="$(val NET_SUBNET)"
CA_V="$(val CA_DATA_VOLUME)"
LD_V="$(val LDAP_DATA_VOLUME)"
LC_V="$(val LDAP_CONFIG_VOLUME)"

# runner 导出给 up.sh / compose / bats 使用
export ENV_FILE="$V2ENV" CONTAINER_PREFIX="$PREFIX"
export ORG_NETWORK="$NET" NET_SUBNET="$SUBNET"
export CA_DATA_VOLUME="$CA_V" LDAP_DATA_VOLUME="$LD_V" LDAP_CONFIG_VOLUME="$LC_V"

# 线上安全哨兵：任何 of-* 容器都不在 runner 的操作范围内（只读核对，不改）
online_guard() {
  local hit
  hit="$(docker ps -aq -f 'name=^of-' 2>/dev/null | while read -r cid; do
    docker inspect -f '{{.Name}}' "$cid" 2>/dev/null | grep -q '^/ofv2-' || echo "$cid"
  done)"
  if [[ -n "$hit" ]]; then
    echo "⚠ 检测到线上 of-* 容器存在（正常）：runner 不会对它们执行 stop/restart/down。" >&2
  fi
}

up_v2() {
  online_guard
  echo "== 建独立网络/卷（幂等，已存在跳过）=="
  docker network inspect "$NET" >/dev/null 2>&1 || docker network create --driver bridge --subnet "$SUBNET" "$NET" >/dev/null
  for v in "$CA_V" "$LD_V" "$LC_V"; do docker volume inspect "$v" >/dev/null 2>&1 || docker volume create "$v" >/dev/null; done
  echo "== 按 manifest 顺序起 ofv2 栈（--no-pull：镜像已在本地，避免重复拉取超时）=="
  JSON=1 bash up.sh --no-pull
}

down_v2() {
  echo "== 仅移除 ofv2-* 容器（不动线上 of-*，保留卷）=="
  for svc in router ldapadmin homepage ldap caddy dnsmasq certs-init; do
    cid="$(docker ps -aq -f "name=^${PREFIX}-${svc}\$" 2>/dev/null | head -1)"
    [[ -n "$cid" ]] && docker rm -f "$cid" >/dev/null 2>&1 && echo "  removed ${PREFIX}-${svc}"
  done
  echo "== 独立网络/卷保留（如需彻底清理：docker network rm $NET && docker volume rm $CA_V $LD_V $LC_V）=="
}

run_bats() {
  if ! command -v bats >/dev/null 2>&1; then
    echo "bats 未安装：跳过行为测试；静态覆盖用 bash tests/check-v2.sh 校验。" >&2
    return 0
  fi
  bats tests/bats/00_full_stack.bats tests/bats/1[0-6]_*.bats tests/bats/S_*.bats
  return $?
}

case "${1:-help}" in
  up)    up_v2 ;;
  down)  down_v2 ;;
  test)  run_bats ;;
  *)
    sed -n '2,9p' "$0"
    echo "用法: run-v2.sh up|down|test"
    echo "  up    建独立资源并按 manifest 起 ofv2 栈（不改线上）"
    echo "  down  只移除 ofv2 容器（保留卷，线上零影响）"
    echo "  test  跑全栈+单服务 bats（需先 up，且需安装 bats）"
    ;;
esac
