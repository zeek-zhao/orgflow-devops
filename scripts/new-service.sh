#!/usr/bin/env bash
# new-service.sh —— M2.0 P4：从 services/_template 生成新服务骨架
#
# 用法：bash scripts/new-service.sh <name>
# 行为：复制 _template/{compose.yml,Dockerfile,README.md} → services/<name>/，
#       把 <SVC> 占位替换为大写环境变量名风格需人工确认（本脚本只做目录级骨架 + 打印 5 步清单）。
# 纪律：绝不自动改 manifest/defaults.env/images.env/images.lock/docs（这些是单一真源，人工改）。
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

name="${1:-}"
if [[ -z "$name" ]]; then
  echo "用法: bash scripts/new-service.sh <name>" >&2
  exit 2
fi
if [[ ! "$name" =~ ^[a-z][a-z0-9-]*$ ]]; then
  echo "✗ 服务名须为小写字母/数字/连字符，且以字母开头: $name" >&2
  exit 2
fi
if [[ -e "services/$name" ]]; then
  echo "✗ services/$name 已存在，拒绝覆盖" >&2
  exit 2
fi

tpl="services/_template"
for f in compose.yml Dockerfile README.md; do
  [[ -f "$tpl/$f" ]] || { echo "✗ 模板缺 $tpl/$f" >&2; exit 2; }
done

mkdir -p "services/$name"
for f in compose.yml Dockerfile README.md; do
  # 仅替换字面服务名占位 <SVC> / <svc>，其余真源变量由人工确认
  sed -e "s/<SVC>/${name}/g" -e "s#<svc>#${name}#g" "$tpl/$f" > "services/$name/$f"
done
echo "✓ 已生成 services/$name/{compose.yml,Dockerfile,README.md}（骨架）"

cat <<EOF

还要手工做的 5 步（缺任一，make check 会红）：
  1) services/manifest.tsv        按 order / depends_on 加一行（up.sh 编排依赖）
  2) config/defaults.env          加 IP_$(echo "$name" | tr 'a-z-' 'A-Z_') 与 P_$(echo "$name" | tr 'a-z-' 'A-Z_')_HTTP（禁写死对外字面端口）
  3) config/images.env            加 IMAGE_$(echo "$name" | tr 'a-z-' 'A-Z_') 与 UPSTREAM_$(echo "$name" | tr 'a-z-' 'A-Z_')
  4) tests/images.lock            加 $name 行（自建 HASHED / 官方镜像 digest）
  5) docs/services/$name.md       新建服务手册并在 docs/README.md 登记（文档双向一致）

自检：make render && make check
EOF
