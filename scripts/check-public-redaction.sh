#!/usr/bin/env bash
# 公开发布合规门禁(#127):扫描导出目录,命中敏感字段即非零退出。
# 用法: bash scripts/check-public-redaction.sh <导出目录>
set -euo pipefail

DEST="${1:-.mirror-export}"
[[ -d "$DEST" ]] || { echo "✗ 导出目录不存在: $DEST" >&2; exit 2; }

PATTERNS=(
    "10\.22\.67\."          # 内网网关段
    "172\.31\.0\."          # orgflow 容器网络
    "gateway-host"         # 内部主机名
    "zeek\.zhao"            # 真实用户名
    "admin\.zeek"           # 旧 uid
    "dev\.zeek"
    "ghp_[A-Za-z0-9]\{20,\}"    # GitHub PAT
    "AKIA[0-9A-Z]\{16\}"        # AWS AccessKey
    "-----BEGIN [A-Z ]*PRIVATE KEY-----"  # 私钥
)
hits=0
for pat in "${PATTERNS[@]}"; do
    while IFS= read -r f; do
        echo "✗ 命中 [$pat] $f" >&2
        hits=$((hits + 1))
    done < <(grep -rEl "$pat" "$DEST" 2>/dev/null || true)
done

# 初始口令明文不允许出现在导出内容里(#84 交付口径只在内部文档)
while IFS= read -r f; do
    echo "✗ 命中 [初始口令明文] $f" >&2
    hits=$((hits + 1))
done < <(grep -rEl "初始.{0,6}123456|password.{0,10}123456" "$DEST" 2>/dev/null \
         | grep -v "check-public-redaction.sh" || true)

# 内部流程文档不得进入导出
for f in 会话交接 待办 M0-验收记录 M0-增量需求总表 派单流程 提交规范 AI会话清单 账号与登录; do
    [[ ! -e "$DEST/docs/$f.md" ]] || { echo "✗ 内部流程文档泄漏: docs/$f.md" >&2; hits=$((hits + 1)); }
done
[[ ! -d "$DEST/docs/task-cards" ]] || { echo "✗ task-cards 不得发布" >&2; hits=$((hits + 1)); }

if (( hits )); then
    echo "✗ 合规门禁:$hits 处命中,禁止发布" >&2
    exit 1
fi
echo "✓ 合规门禁通过: $DEST 无敏感字段"
