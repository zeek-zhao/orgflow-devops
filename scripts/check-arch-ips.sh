#!/usr/bin/env bash
# 核对所有含固定 IP 表的文档与真实容器是否一致。
#
# 为什么需要这个：架构图上的 IP 是排查时唯一的定位依据。表错了不会报错，
# 只会让人对着错误的地址查半天，最后得出「服务没起来」的假结论。
#
# ★ 为什么要核对**多份**文档（2026-11-01 踩到）：
#   原来只查 docs/network/arch.md，于是 docs/会话交接.md 的同一张表漏了
#   jenkins-agent（172.31.0.27）一整行，没有任何东西会报警。而交接文档是
#   接手人**最先读**的那份 —— 它错了比 arch.md 错了更贵。
#
# 双向比对：
#   1. 每份文档表里每一行 → 容器真实地址
#   2. compose 里每个 ipv4_address → 至少有一份文档写了这一行
#   3. 文档之间同一服务的 IP 必须相同（防止两份表各自漂移）
#
# 用法：
#   bash scripts/check-arch-ips.sh            # 需要栈已启动
#   bash scripts/check-arch-ips.sh --static   # 只比 compose 与文档，不起容器

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE_FILE="$ROOT/docker-compose.yml"
STATIC=0
[[ "${1:-}" == "--static" ]] && STATIC=1

# 新增含固定 IP 表的文档时，加到这个数组里。每一份都必须能解析出至少一行，
# 否则判定为「表格格式变了」—— 静默通过比报错危险得多。
DOCS=(
    "$ROOT/docs/network/arch.md"
    "$ROOT/docs/会话交接.md"
)

[[ -f "$COMPOSE_FILE" ]] || { echo "找不到 $COMPOSE_FILE" >&2; exit 1; }
for doc in "${DOCS[@]}"; do
    [[ -f "$doc" ]] || { echo "找不到 $doc" >&2; exit 1; }
done

# 文档表格行形如：| `172.31.0.2` | dnsmasq | 53 | — | — |
doc_rows() {
    awk -F'|' '
        /^\|[[:space:]]*`172\.31\.0\./ {
            ip = $2; svc = $3
            gsub(/[`[:space:]]/, "", ip)
            gsub(/[[:space:]]/, "", svc)
            if (ip != "" && svc != "") print ip "\t" svc
        }
    ' "$1"
}

fail=0

# ---- 1. 文档表 → 汇总（顺带检查文档之间是否一致）----
declare -A DOC_IP=()
declare -A DOC_ORIGIN=()

for doc in "${DOCS[@]}"; do
    name="$(basename "$doc")"
    count=0
    while IFS=$'\t' read -r ip svc; do
        [[ -z "${ip:-}" ]] && continue
        if [[ -n "${DOC_IP[$svc]:-}" && "${DOC_IP[$svc]}" != "$ip" ]]; then
            echo "  ✗ $svc 在文档之间不一致：${DOC_ORIGIN[$svc]} 写 ${DOC_IP[$svc]}，$name 写 $ip" >&2
            fail=1
        fi
        DOC_IP["$svc"]="$ip"
        DOC_ORIGIN["$svc"]="$name"
        count=$((count + 1))
    done < <(doc_rows "$doc")

    if [[ $count -eq 0 ]]; then
        echo "  ✗ $name 里没解析出任何 IP 行，表格格式可能变了" >&2
        fail=1
    else
        echo "  ✓ $name 解析到 $count 行"
    fi
done

if [[ ${#DOC_IP[@]} -eq 0 ]]; then
    echo "所有文档都没解析出 IP 行，表格格式可能变了" >&2
    exit 1
fi

echo
echo "文档表格合计 ${#DOC_IP[@]} 个服务"

if [[ $STATIC -eq 0 ]]; then
    for svc in "${!DOC_IP[@]}"; do
        cid=$(docker compose ps -q "$svc" 2>/dev/null || true)
        if [[ -z "$cid" ]]; then
            # nexus 不在 compose 里（#46），它是 job 用 docker run 创建的。
            # 按容器名兜底，否则这一行会永远报「容器未运行」——
            # 而那个报错看起来像服务挂了，其实是查法不对。
            cid=$(docker ps -q -f "name=^of-${svc}$" 2>/dev/null || true)
        fi
        if [[ -z "$cid" ]]; then
            echo "  ✗ $svc: 容器未运行（文档写 ${DOC_IP[$svc]}）" >&2
            fail=1
            continue
        fi
        # 用 docker inspect 而不是容器内 ip/ipconfig：oauth2-proxy 是 distroless，
        # 里面没有 ip 命令，用 exec 会在那一行永远失败
        actual=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' "$cid" \
                 | tr ' ' '\n' | grep -E '^172\.31\.0\.' | head -1 || true)
        if [[ -z "$actual" ]]; then
            echo "  ✗ $svc: 容器没有 172.31.0.x 地址" >&2
            fail=1
        elif [[ "$actual" != "${DOC_IP[$svc]}" ]]; then
            echo "  ✗ $svc: 文档 ${DOC_IP[$svc]} / 实际 $actual" >&2
            fail=1
        else
            echo "  ✓ $svc $actual"
        fi
    done
fi

# ---- 2. compose → 表 ----
echo
echo "compose 里的固定 IP 是否都写进了文档："
while read -r svc ip; do
    if [[ -z "${DOC_IP[$svc]:-}" ]]; then
        echo "  ✗ $svc ($ip) 在 compose 里有固定 IP，但文档表里没有这一行" >&2
        fail=1
    elif [[ "${DOC_IP[$svc]}" != "$ip" ]]; then
        echo "  ✗ $svc: compose $ip / 文档 ${DOC_IP[$svc]}" >&2
        fail=1
    fi
done < <(awk '
    /^  [a-z0-9-]+:$/ { svc = $1; sub(/:$/, "", svc) }
    /ipv4_address:[[:space:]]*172\.31\./ {
        ip = $2
        gsub(/[[:space:]]/, "", ip)
        if (svc != "" && ip != "") print svc "\t" ip
    }
' "$COMPOSE_FILE")

if [[ $fail -ne 0 ]]; then
    echo
    echo "不一致。改 compose 或改文档里的 IP 表（${DOCS[*]##*/}），三方必须逐行相同。" >&2
    exit 1
fi

echo
echo "文档与真实容器一致。"
