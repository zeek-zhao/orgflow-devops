#!/usr/bin/env bash
# image-hash.sh —— 按服务计算镜像内容标识（r5 §2：替代不可靠的 CI digest 回填链路）
#
# 为什么：CI 每次构建的 imageId/manifest digest 都随机变化，把 digest 回填进 compose
# 会造成「配置领先镜像」的死循环（jaune r5 P2）。改用「Dockerfile + 它 COPY 的真源文件」
# 的内容哈希作标识：只要构建输入不变，哈希恒定；输入一变，哈希必变，可被门禁拦截。
#
# 用法：bash scripts/image-hash.sh <service>
# 输出：64hex（stdout 单行，供 check-images.sh --mode=lock 比对 LK_ctx）
# 口径：Dockerfile 自身 + 其中 COPY/ADD 引用的、服务目录内的真源文件（跳过 build/ 生成物）。
#       build/ 是 sync-build-context.sh 从 config/ 派生的生成物，不是真源，不纳入。
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

svc="${1:-}"
[[ -n "$svc" && -d "services/$svc" ]] || { echo "用法: $0 <service>（如 jenkins / jenkins-agent）" >&2; exit 2; }
df="services/$svc/Dockerfile"
[[ -f "$df" ]] || { echo "✗ 缺 services/$svc/Dockerfile" >&2; exit 1; }

files=("$df")
# 解析 COPY/ADD 的第一个源参数；只纳入服务目录内真实存在的真源文件。
while read -r _op src _rest; do
  [[ -z "$src" ]] && continue
  [[ "$src" == --from=* || "$src" == build/* ]] && continue
  f="services/$svc/$src"
  [[ -f "$f" ]] && files+=("$f")
done < <(grep -E '^(COPY|ADD)[[:space:]]' "$df" || true)

# 文件列表排序去重；逐文件输出「路径 + 内容 sha256」再汇总为一个 64hex。
printf '%s\n' "${files[@]}" | sort -u | while read -r f; do
  printf '%s  %s\n' "$f" "$(sha256sum "$f" | awk '{print $1}')"
done | sha256sum | awk '{print $1}'
