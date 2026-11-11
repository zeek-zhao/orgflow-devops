#!/usr/bin/env bash
# 公开面合规门禁：本仓库要被任何人 clone，命中有真实内网/凭据特征的串就非零退出。
#
# 用法：
#   bash scripts/check-public-redaction.sh            # 扫仓根（默认）
#   bash scripts/check-public-redaction.sh <目录>      # 扫指定目录（CI 里传 .）
#
# 规则为什么长这样（单仓化时重定，旧规则是双仓导出时代抄来的）：
#   - `172.31.0.*` 移出规则：这是 compose 自己的容器网段，ADR-13 整篇在讲它，
#     属于设计常量。把它当敏感串，等于逼着改掉整套网络设计。
#   - `zeek.zhao` 移出规则：仓库公开后它就在每条提交的 author 里，文档里抹掉是自欺，
#     而且会让「文档里怎么写提交人」和 `git log` 互相矛盾。
#   - 保留真实内网网段 / 内部主机名 / 内网组织域名：这些真可路由，写出来等于给
#     攻击者一份入口清单。
#   - 保留凭据形态（PAT/AWS key/私钥块/口令明文）：公开仓的凭据不是「敏感」而是
#     「已泄漏」，必须零容忍。
#
# 实现注意：整轮扫描只起两次 grep，不按「每文件×每规则」起进程。
# 上一版那样写在 Linux 上没问题，在 Windows Git Bash 上是 ~350 文件 × 9 规则 ≈ 3000
# 次进程创建，几十秒还跑不完，最终被外层超时杀掉 —— 表现为「没有任何输出、退出码 1」，
# 看起来像门禁拦住了，实际是门禁没跑完。这种假红比漏报更浪费时间。
set -euo pipefail

TARGET="${1:-.}"
[[ -d "$TARGET" ]] || { echo "✗ 目录不存在: $TARGET" >&2; exit 2; }

# 本脚本自身必然含有下面这些正则的字面形式，扫自己会自我命中。
SELF="$TARGET/scripts/check-public-redaction.sh"

# 文件清单用 git 跟踪集：天然排除 .git/、out/、以及被 gitignore 的本地产物。
# CI 里也成立（checkout 出来的就是跟踪集）。不在 git 仓库里时退化成 find。
if git -C "$TARGET" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    list_files() {
        git -C "$TARGET" ls-files -z | tr '\0' '\n' | sed "s|^|$TARGET/|"
    }
else
    list_files() {
        find "$TARGET" -type f \
            -not -path "$TARGET/.git/*" -not -path "$TARGET/out/*" \
            -not -path "$TARGET/node_modules/*"
    }
fi

# 规则名与正则成对出现：报告要能说清「命中了哪条」，只说「有命中」等于没说。
RULES=(
    # 只锁前两段：仍然拦住真实网段，但公开脚本里不写全第三段。
    # 注意不能用 \d：POSIX ERE 里没有 \d，grep 会当成字母 d，整条规则静默失效。
    "内网网段|10\.22\.[0-9]+\."
    # 用形状而不是字面值：拦住真名，但不在公开脚本里把前缀写全。
    "内部主机名|[A-Z]{3}-ED-[A-Z]{3}[0-9]+"
    # 同样是形状：只拦「*wireless.com」这类内网域名，不在公开脚本里写全组织名。
    "内网组织域名|[a-z0-9-]+wireless\.com"
    "GitHub PAT|ghp_[A-Za-z0-9]{20,}"
    "GitHub PAT|github_pat_[A-Za-z0-9_]{20,}"
    "AWS AccessKey|AKIA[0-9A-Z]{16}"
    "私钥块|-----BEGIN [A-Z ]*PRIVATE KEY-----"
)

combined=""
for rule in "${RULES[@]}"; do
    pattern="${rule#*|}"
    combined="${combined:+$combined|}$pattern"
done

mapfile -t files < <(list_files | grep -vxF "$SELF" || true)

hits=0
report() { printf '✗ 命中 [%s] %s\n' "$1" "$2" >&2; hits=$((hits + 1)); }

if ((${#files[@]})); then
    # 一次 grep 扫全部文件；命中行再回头判断属于哪条规则。
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        file="${line%%:*}"
        rest="${line#*:}"
        content="${rest#*:}"
        for rule in "${RULES[@]}"; do
            name="${rule%%|*}"
            pattern="${rule#*|}"
            if printf '%s' "$content" | grep -qE -- "$pattern"; then
                report "$name" "${file#"$TARGET/"}"
            fi
        done
    done < <(grep -InHE -- "$combined" "${files[@]}" 2>/dev/null || true)

    # 口令明文：只在「明确在说口令」的上下文里判，避免误伤 0123456789 这类占位串。
    # 判据来自一次真事故：README 曾直接写出目录初始口令，而那个值在部署机上真在用。
    password_re='(初始口令|初始密码|initial password|默认口令|默认密码)[^"]{0,20}\b123456\b|password["'"'"']?[[:space:]]*[:=][[:space:]]*["'"'"']?123456\b'
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        # cut 取到的是 "文件:行号"，两种分隔都要剥掉，否则报告里会带绝对路径和行号，
        # 与上面那条规则的「相对路径」格式不一致，看起来像两个不同的东西。
        hit_file="${line%:*}"      # 去掉 "内容"
        hit_file="${hit_file%:*}"  # 再去掉 ":行号"
        report "口令明文" "${hit_file#"$TARGET/"}"
    done < <(grep -InHE -- "$password_re" "${files[@]}" 2>/dev/null || true)
fi

# 内部流程文档按「最小披露」不再随仓库分发：它们含内网拓扑、验收取证过程与派工细节。
# 单独立一条而不是只靠上面的模式：整篇加回来可能不含任何敏感串。
INTERNAL_DOCS=(
    docs/会话交接.md
    docs/待办.md
    docs/M0-验收记录.md
    docs/M0-增量需求总表.md
    docs/派单流程.md
    docs/提交规范.md
    docs/AI会话清单.md
    docs/账号与登录.md
    docs/身份命名规范.md
)
for doc in "${INTERNAL_DOCS[@]}"; do
    if [[ -e "$TARGET/$doc" ]]; then
        report "内部流程文档回流" "$doc"
    fi
done
if [[ -d "$TARGET/docs/task-cards" ]]; then
    report "内部流程文档回流" "docs/task-cards/"
fi

if (( hits )); then
    echo "✗ 公开面合规门禁：$hits 处命中，禁止发布" >&2
    exit 1
fi
echo "✓ 公开面合规门禁通过：$TARGET 无真实内网标识、无凭据形态、无内部流程文档"
