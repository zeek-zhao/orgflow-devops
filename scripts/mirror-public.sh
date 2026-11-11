#!/usr/bin/env bash
# 生成公开镜像仓内容(#127):私有仓 → orgflow-devops(public)导出目录。
#
# 原则(2026-11-11 grill 定案):
#   - 发布代码框架 + 通用运维文档;内部流程文档(会话交接/待办/验收记录/
#     需求总表/task-cards/派单流程/提交规范/AI会话清单/账号与登录)不发布
#   - 敏感字段泛化:内网 IP → RFC5737 文档地址,内部主机名/真实用户名 → 占位符
#   - 导出完必须跑 scripts/check-public-redaction.sh 门禁,非零即不得发布
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="${1:-$ROOT/.mirror-export}"
rm -rf "$DEST"
mkdir -p "$DEST"

# ---- 导入:代码 + 通用文档(排除内部流程文档)----
copy() { # copy <相对路径>...
    # 必须遍历全部参数。原实现只吃 $1，`copy a b c` 里 b、c 被静默丢弃
    # （P0-1：docker-compose.yml / .env.example 就这样没进过发布物，
    #  公开仓克隆后 `cp .env.example .env` 第一步必失败，而 CI 不覆盖导出物所以一直没红）
    local rel
    for rel in "$@"; do
        mkdir -p "$DEST/$(dirname "$rel")"
        cp -R "$ROOT/$rel" "$DEST/$rel"
    done
}
for d in services scripts config tests tools; do copy "$d"; done
# docs 只发布通用运维文档;内部流程文档(交接/待办/验收/需求/派单/提交规范/
# AI会话清单/账号与登录/task-cards)不发布——门禁脚本双向拦截
for f in ADR-13-域名路由.md M0-最小核心.md M0-测试体系.md M0-镜像与CI.md \
         使用说明.md 备份与恢复.md; do copy "docs/$f"; done
copy docs/network
copy docs/services
copy Makefile docker-compose.yml docker-compose.ghcr.yml .env.example .gitignore
copy .github/workflows/test.yml
mkdir -p "$DEST/.github/workflows"

# public/ 目录(公开仓专属文件:合规四件套/双语 README/合规 CI/第三方 NOTICES/许可证全文)
# 原样进导出——注意 public/.gitignore 会覆盖上面导出的内部版(公开侧规则更严)
cp -R "$ROOT/public/." "$DEST/"

# 构建产物一律不进发布物(P1-1):.pyc 是编译期产物,且字节码可能内嵌绝对路径
find "$DEST" -type d -name __pycache__ -prune -exec rm -rf {} + 2>/dev/null || true
find "$DEST" -type f -name '*.pyc' -delete 2>/dev/null || true

PY="$(command -v python3 || command -v python)"
# Git Bash（Windows）下把路径转成原生形式再交给 python，否则 /d/xxx 会被解释成 D:\d\xxx。
# Linux（213 / CI）没有 cygpath，原样返回。
native() { if command -v cygpath >/dev/null 2>&1; then cygpath -w "$1"; else printf '%s' "$1"; fi; }

# ---- 敏感字段泛化 ----
# 刻意保留 GitHub 账号名 zeek-zhao(github.com/zeek-zhao、ghcr.io/zeek-zhao):
#   1. 它是发布物的**运行时依赖** —— compose 里的 image 引用必须真实可拉;
#   2. 它本就是公开信息(仓库地址与 GHCR 包名),不是秘密。
# 曾经写成 s/zeek-zhao/your-org/g,后果是两个:
#   - 公开仓的 docker-compose.ghcr.yml 全指向 ghcr.io/your-org/... → 拉不到;
#   - SECURITY.md 的上报入口变成 github.com/your-org/... → 404。
# 真正要挡住的是「带点的账号名」zeek.zhao(内部 uid),那条规则保留。
find "$DEST" -type f \( -name "*.md" -o -name "*.sh" -o -name "*.py" -o -name "*.yml" \
    -o -name "*.yaml" -o -name "*.groovy" -o -name "*.ps1" -o -name "Makefile" \
    -o -name "*.bats" -o -name "*.bat" -o -name "*.j2" -o -name "*.tmpl" -o -name "*.ldif" \) -print0 | while IFS= read -r -d '' f; do
    sed -i \
        -e 's/10\.22\.67\.x/192.0.2.x/g' \
        -e 's/10\.22\.67\.213/192.0.2.10/g' \
        -e 's/10\.22\.67\.214/192.0.2.11/g' \
        -e 's/10\.22\.67\.2[01][0-9]/192.0.2.12/g' \
        -e 's/10\.22\.67\.[0-9]\+/192.0.2.10/g' \
        -e 's/172\.31\.0\.\([0-9]\+\)/198.51.100.\1/g' \
        -e 's/172\.31\.255\.[0-9]\+/198.51.100.250/g' \
        -e 's/172\.1[78]\.\([0-9]\+\.[0-9]\+\)/198.51.100.\1/g' \
        -e 's/172\.31\.0\.x/198.51.100.x/g' \
        -e 's/RSZ-ED-SVR146/gateway-host.internal/g' \
        -e 's/zeek\.zhao/ops.admin/g' \
        -e 's/admin\.zeek/platform.admin/g' \
        -e 's/dev\.zeek/platform.dev/g' \
        -e 's/123456/<initial-password>/g' \
        "$f"
done

# ---- 发布物自洽:指向未导出文档的链接降级为纯文本,再校验零死链(P1-3)----
# 内部文档(会话交接/待办/验收记录/task-cards)不发布,产品文档却会引用它们,
# 导出后这些链接必然悬空。降级而不是删引用:读者仍知道「此处另有内部记录」,
# 且内部仓原文不受影响。
"$PY" "$(native "$ROOT/scripts/check_export_links.py")" "$(native "$DEST")" --strip
"$PY" "$(native "$ROOT/scripts/check_export_links.py")" "$(native "$DEST")"

# ---- 发布物冒烟:缺任一即不得发布(P0-1 防回归)----
required="Makefile .env.example docker-compose.yml docker-compose.ghcr.yml .gitignore LICENSE README.md THIRD_PARTY_NOTICES.md scripts/check-public-redaction.sh"
missing=0
for f in $required; do
    [ -e "$DEST/$f" ] || { echo "发布物缺文件: $f" >&2; missing=1; }
done
[ -d "$DEST/licenses" ] || { echo "发布物缺目录: licenses/(第三方许可证全文)" >&2; missing=1; }
[ "$missing" -eq 0 ] || { echo "导出物不完整,拒绝发布" >&2; exit 1; }

echo "导出完成: $DEST"
echo "下一步: bash scripts/check-public-redaction.sh $DEST"
