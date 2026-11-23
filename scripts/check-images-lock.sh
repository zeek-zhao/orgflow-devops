#!/usr/bin/env bash
# check-images-lock.sh —— 摘要一致性门禁（AC-10）
# 校验 compose 里引用的每个 digest 与 tests/images.lock 登记一致。
# 从 config/images.env 取值，保证 config 与 lock 同源。
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
rc=0
[[ -f config/images.env ]] || { echo "✗ 缺 config/images.env" >&2; exit 1; }
[[ -f tests/images.lock ]] || { echo "✗ 缺 tests/images.lock" >&2; exit 1; }
declare -A ENV_D LOCK_D
while IFS='=' read -r k v; do [[ "$k" =~ ^IMAGE_ ]] && ENV_D["${k#IMAGE_}"]="$v"; done < <(grep -vE '^\s*#|^\s*$' config/images.env)
while IFS='=' read -r k v; do LOCK_D["$k"]="$v"; done < <(grep -vE '^\s*#|^\s*$' tests/images.lock)
for k in "${!ENV_D[@]}"; do
  lk="$(echo "$k" | tr '[:upper:]' '[:lower:]' | tr '_' '-')"
  if [[ -z "${LOCK_D[$lk]:-}" ]]; then echo "✗ images.lock 缺 $lk" >&2; rc=1
  elif [[ "${LOCK_D[$lk]}" != "${ENV_D[$k]}" ]]; then echo "✗ $lk digest 不一致: images.env=${ENV_D[$k]} lock=${LOCK_D[$lk]}" >&2; rc=1; fi
done
[[ $rc -eq 0 ]] && echo "✓ 摘要一致：config/images.env 与 tests/images.lock ${#ENV_D[@]} 项全部匹配"
exit $rc
