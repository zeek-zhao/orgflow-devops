#!/usr/bin/env bash
# check-upstream-digest.sh —— 上游 digest 登记表一致性门禁（v1.0 §4 / AC-2）
# 校验每个 services/<svc>/Dockerfile 的 FROM <ref>@sha256 与本登记表一致。
# 登记表真源：docs/engineering/镜像与供应链.md §2 的代码块。
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
REG="docs/engineering/镜像与供应链.md"
rc=0
[[ -f "$REG" ]] || { echo "✗ 缺 $REG" >&2; exit 1; }

# 解析登记表代码块：name<TAB>reference<TAB>sha256
declare -A REF BY_NAME
while IFS=$'\t' read -r name ref digest; do
  [[ "$name" =~ ^[a-z] ]] || continue
  REF["$name"]="$ref"
  BY_NAME["$ref"]="$digest"
done < <(sed -n '/^```$/,/^```$/p' "$REG" | grep -E '^(ubuntu|caddy|ldap|ldapadmin|homepage)[[:space:]]')

# 每个 Dockerfile 的 FROM 必须命中登记表且 digest 一致
shopt -s nullglob
n=0
for df in services/*/Dockerfile; do
  from="$(grep -m1 '^FROM ' "$df" 2>/dev/null || true)"
  [[ -n "$from" ]] || continue
  # 取 FROM 的第 2 个字段（ref@sha256）
  img="$(echo "$from" | awk '{print $2}')"
  ref="${img%@*}"
  dg="${img#*@}"
  if [[ -z "${BY_NAME[$ref]:-}" ]]; then
    echo "✗ $df 的 FROM 上游 $ref 不在登记表" >&2; rc=1; continue
  fi
  if [[ "$dg" != "${BY_NAME[$ref]}" ]]; then
    echo "✗ $df 的 FROM digest 与登记表不符: $dg != ${BY_NAME[$ref]}" >&2; rc=1; continue
  fi
  echo "  ✓ $(basename "$(dirname "$df")") FROM $ref@${dg:0:19}…"
  n=$((n+1))
done
[[ $rc -eq 0 ]] && echo "✓ 上游 digest：${n} 个 Dockerfile 的 FROM 与登记表一致（${#BY_NAME[@]} 条登记）"
exit $rc
