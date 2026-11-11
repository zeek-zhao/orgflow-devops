#!/usr/bin/env bash
# =============================================================================
# check-image-source.sh —— 镜像来源闸门
#
#   为什么需要它：默认从 GHCR 拉镜像后，会出现一种「看起来成功的失败」——
#   改了 Dockerfile 但没等 CI 跑完就 make deploy，Compose 顺利拉到**上一版**
#   镜像、所有健康检查通过、端点自检全绿，部署的却是旧代码。
#   本仓的注释里反复警告这类失败模式，这里是它的机械防线。
#
#   判据不是「HEAD 是否等于 origin/main」（文档提交也会让它们不等，
#   那会天天误报），而是「自 pinned-at 那次构建以来，镜像上下文有没有变过」：
#   变了就等于本地镜像落后于源码，硬失败。
#
#   pinned-at 由 scripts/pin-images.sh 写入 docker-compose.ghcr.yml 头部，
#   值是产出这批 digest 的那次提交。#134 要的「期望值溯源」，这里是第一处落地。
#
#   用法：
#     bash scripts/check-image-source.sh          # make deploy 前置
#     USE_GHCR=0 bash scripts/check-image-source.sh   # 本地构建模式，直接放行
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

OVERLAY="docker-compose.ghcr.yml"
LOCK="tests/images.lock"

# 与 .github/workflows/images.yml 的 paths 完全一致：这棵树里的任何改动
# 都会改变镜像内容，因此都必须重建镜像，否则本地 digest 就过期了。
CONTEXTS=(
  tests/harness
  services/router
  services/dnsmasq
  services/jenkins
  tools/jjb
  tools/jenkins
  tools/jenkins-agent
  .github/workflows/images.yml
  .github/scripts
)

if [[ "${USE_GHCR:-1}" != 1 ]]; then
  echo "== 镜像来源：本地构建（USE_GHCR=0）=="
  echo "  跳过「镜像是否落后于源码」校验 —— 这条路径的命令自己会 build。"
  echo "  部署到共享环境前请改用默认的 GHCR 路径：make deploy"
  exit 0
fi

fail() {
  printf '\n[image-guard] ✗ %s\n' "$1" >&2
  shift
  printf '%s\n' "$@" >&2
  exit 1
}

# ── 1. digest 必须锁死，且不能是占位 ─────────────────────────────────────
[[ -f "$OVERLAY" ]] || fail "缺少 $OVERLAY" "  这是 GHCR 覆盖层，缺失时 Compose 会退回本地构建。"

placeholders=$(grep -vE '^[[:space:]]*#' "$LOCK" 2>/dev/null | grep -c '待构建后回填' || true)
if [[ "${placeholders:-0}" != 0 ]]; then
  fail "$LOCK 仍有 $placeholders 条「待构建后回填」占位" \
       "  digest 还没产生，说明 images.yml 没跑过或没跑完。" \
       "  修：等 Images 工作流成功 → make images-pin"
fi

# 覆盖层里每一个 image 都必须是 @sha256 锁定的自建/mirror 镜像。
# 不解析合并后的 Compose（那要 Docker），直接扫这一层的文本：
# 覆盖层是唯一决定 GHCR 路径镜像的地方，扫它等价且无需运行时依赖。
#
# ★ 用 python3 而不是 awk：mawk（Debian/Ubuntu 默认 awk）不支持 `{64}` 区间表达式，
#   会把 `[a-f0-9]{64}` 当字面量匹配 → 每一条都被判成「未锁定」。这个 bug 在
#   Git Bash（gawk）下完全看不出来，在 Ubuntu 上第一个用例就红。
unlocked=$(python3 - "$OVERLAY" <<'PY'
import re
import sys

bad = []
for line in open(sys.argv[1], encoding="utf-8"):
    stripped = line.strip()
    if stripped.startswith("image:"):
        reference = stripped.split(":", 1)[1].split("#")[0].strip()
    elif stripped.startswith("x-m0-test-image:"):
        reference = stripped.split(":", 1)[1].strip()
    else:
        continue
    if not re.fullmatch(r"\S+@sha256:[a-f0-9]{64}", reference):
        bad.append(reference)
print("\n".join(bad))
PY
)
if [[ -n "$unlocked" ]]; then
  fail "$OVERLAY 有未按 digest 锁定的镜像" \
       "$(printf '    %s\n' $unlocked)" \
       "  浮动的 tag 会在不同机器上拉到不同镜像，部署结果不可复现。" \
       "  修：make images-pin"
fi

# ── 2. 有没有 git 元数据（zip 下载的副本没有） ───────────────────────────
if ! git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "== 镜像来源：GHCR（digest 已锁定）=="
  echo "  ⚠ 没有 .git 元数据，无法判断「镜像是否落后于源码」，跳过该判据。"
  echo "    从压缩包解压的副本属正常情况：它的 digest 与它自己的源码同批产出。"
  exit 0
fi

# ── 3. pinned-at 必须存在且在本仓库里 ────────────────────────────────────
pinned_at=$(sed -n 's/^# pinned-at:[[:space:]]*//p' "$OVERLAY" | head -1 | tr -d '[:space:]')
if [[ -z "$pinned_at" ]]; then
  fail "$OVERLAY 缺少 # pinned-at: 标注，无法判断镜像是否落后于源码" \
       "  这一行由 scripts/pin-images.sh 写入，记录产出当前 digest 的那次提交。" \
       "  修：make images-pin（会一并补上）"
fi

if ! git -C "$ROOT" cat-file -e "${pinned_at}^{commit}" 2>/dev/null; then
  fail "找不到提交 $pinned_at（pinned-at 指向的提交不在本地）" \
       "  浅克隆或换过克隆时常见。镜像与源码的对应关系无法验证。" \
       "  修：git fetch --unshallow   或   git fetch origin $pinned_at"
fi

# ── 4. 镜像上下文自 pinned-at 以来必须没变过 ─────────────────────────────
changed=$(git -C "$ROOT" diff --name-only "$pinned_at" HEAD -- "${CONTEXTS[@]}")
dirty=$(git -C "$ROOT" status --porcelain -- "${CONTEXTS[@]}")

if [[ -n "$changed" || -n "$dirty" ]]; then
  detail=""
  [[ -n "$changed" ]] && detail="${detail}$(printf '    已提交未构建: %s\n' $changed)"
  [[ -n "$dirty" ]] && detail="${detail}$(printf '    工作区未提交: %s\n' "${dirty}")"
  fail "镜像落后于源码（pinned-at=${pinned_at:0:8}）" \
       "$detail" \
       "  现在部署会拉到上一版镜像：拉取成功、健康检查通过、跑的却是旧代码。" \
       "  修（按顺序）：" \
       "    1) 提交并合并到 main；" \
       "    2) 等 Images 工作流（Actions → Images）构建推送完成；" \
       "    3) 本地 git pull 后执行 make images-pin；" \
       "  只改文档/脚本不走镜像上下文，不会触发这条判据。"
fi

echo "== 镜像来源：GHCR（digest 已锁定，pinned-at=${pinned_at:0:8}，镜像上下文无改动）=="
