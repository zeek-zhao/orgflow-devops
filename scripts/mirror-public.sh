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
copy() { # copy <相对路径>
    mkdir -p "$DEST/$(dirname "$1")"
    cp -R "$ROOT/$1" "$DEST/$1"
}
for d in services scripts config tests tools; do copy "$d"; done
# docs 只发布通用运维文档;内部流程文档(交接/待办/验收/需求/派单/提交规范/
# AI会话清单/账号与登录/task-cards)不发布——门禁脚本双向拦截
for f in ADR-13-域名路由.md M0-最小核心.md M0-测试体系.md M0-镜像与CI.md \
         使用说明.md 备份与恢复.md; do copy "docs/$f"; done
copy docs/network
copy docs/services
copy Makefile docker-compose.yml docker-compose.ghcr.yml .env.example
copy .github/workflows/test.yml
mkdir -p "$DEST/.github/workflows"

# public/ 目录(公开仓专属文件:合规四件套/双语 README/合规 CI)原样进导出
cp -R "$ROOT/public/." "$DEST/"

# ---- 敏感字段泛化 ----
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
        -e 's/gateway-host/gateway-host.internal/g' \
        -e 's/zeek\.zhao/ops.admin/g' \
        -e 's/zeek-zhao/your-org/g' \
        -e 's/admin\.zeek/platform.admin/g' \
        -e 's/dev\.zeek/platform.dev/g' \
        -e 's/123456/<initial-password>/g' \
        "$f"
done

echo "导出完成: $DEST"
echo "下一步: bash scripts/check-public-redaction.sh $DEST"
