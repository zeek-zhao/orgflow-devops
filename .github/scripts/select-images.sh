#!/usr/bin/env bash
# 按改动路径裁剪 images.yml 的构建 matrix。
#
# 用法：
#   select-images.sh --all             # 全量（workflow_dispatch / 新建分支 / 判断不了影响）
#   select-images.sh --dump-table      # 打印 image<TAB>context，供 test_ci.py 与 images.yml 对齐
#   git diff --name-only | select-images.sh    # 从 stdin 读改动路径，一行一个
#
# 输出（同时写 stdout 和 $GITHUB_OUTPUT，GITHUB_OUTPUT 未设置时只写 stdout）：
#   any=true|false                     # false 时调用方必须用 if 跳过 job
#   matrix={"include":[{"image":"...","context":"..."}]}
#   images=router jenkins              # 空格分隔，仅用于 job summary
#
# 判定原则：宁可多建，不可漏建。判断不了影响范围就退化成全量。

set -euo pipefail

# 镜像 → 构建上下文。六个上下文都是自包含目录（Dockerfile 不会 COPY 到自己目录之外，
# test_ci.py 有断言守着），所以「触发路径」恒为 <context>/**，不需要单独维护路径表。
table() {
    cat <<'EOF'
router	services/router
jjb	tools/jjb
jenkins	tools/jenkins
jenkins-agent	tools/jenkins-agent
m0-test	tests/harness
dnsmasq	services/dnsmasq
EOF
}

emit() {
    printf '%s=%s\n' "$1" "$2"
    if [ -n "${GITHUB_OUTPUT:-}" ]; then
        printf '%s=%s\n' "$1" "$2" >>"$GITHUB_OUTPUT"
    fi
}

case "${1:-}" in
    --dump-table)
        table
        exit 0
        ;;
    --all)
        full=1
        changed=""
        ;;
    "")
        full=0
        # stdin 是管道时才读；交互终端下读会挂住，直接报错更清楚
        if [ -t 0 ]; then
            echo "需要从 stdin 读改动路径，或显式传 --all" >&2
            exit 2
        fi
        changed="$(cat)"
        ;;
    *)
        echo "未知参数: $1" >&2
        exit 2
        ;;
esac

declare -A ctx_of=()
while IFS=$'\t' read -r image context; do
    ctx_of["$image"]="$context"
done < <(table)

paths=()
if [ -n "$changed" ]; then
    mapfile -t paths <<<"$changed"
fi

# .github/** 改动影响的是构建流程本身，判断不了波及哪些镜像 → 全量
if [ "$full" = 0 ] && [ "${#paths[@]}" -gt 0 ]; then
    for p in "${paths[@]}"; do
        case "$p" in
            .github/*)
                echo "改动涉及 .github/**，退化为全量构建" >&2
                full=1
                break
                ;;
        esac
    done
fi

hits() {
    [ "${#paths[@]}" -eq 0 ] && return 1
    local p
    for p in "${paths[@]}"; do
        [[ "$p" == "$1"/* ]] && return 0
    done
    return 1
}

selected=()
while IFS=$'\t' read -r image context; do
    if [ "$full" = 1 ] || hits "$context"; then
        selected+=("$image")
    fi
done < <(table)

matrix='{"include":['
sep=''
if [ "${#selected[@]}" -gt 0 ]; then
    for image in "${selected[@]}"; do
        matrix+="${sep}{\"image\":\"${image}\",\"context\":\"${ctx_of[$image]}\"}"
        sep=','
    done
fi
matrix+=']}'

if [ "${#selected[@]}" -eq 0 ]; then
    emit any false
    emit matrix "$matrix"
    emit images ""
    echo "改动没有落在任何镜像上下文里，本次不构建" >&2
else
    emit any true
    emit matrix "$matrix"
    emit images "${selected[*]}"
fi
