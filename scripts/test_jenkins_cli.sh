#!/usr/bin/env bash
# jenkins-cli.sh 离线自检：只做静态检查，不连 Jenkins、不需要凭据。
# 防的是「脚本还在但纪律被改坏」：凭据硬编码、改用 crumb、丢掉 set +x、
# 或文档把 consoleText / api/json 冒充成官方文档规定。
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLI="$ROOT/scripts/jenkins-cli.sh"
DOC="$ROOT/docs/services/jenkins.md"
fail=0
ok()  { echo "  ✓ $*"; }
bad() { echo "  ✗ $*" >&2; fail=1; }

[[ -f "$CLI" ]] || { echo "找不到 $CLI" >&2; exit 1; }
[[ -f "$DOC" ]] || { echo "找不到 $DOC" >&2; exit 1; }

if bash -n "$CLI"; then ok "bash -n 语法通过"; else bad "bash -n 语法失败"; fi

for cmd in list get run log; do
  if grep -qE "^cmd_${cmd}[(][)]" "$CLI"; then ok "子命令 $cmd 存在"; else bad "子命令 $cmd 缺失"; fi
done

if grep -q '^set +x' "$CLI"; then ok "显式 set +x（防凭据回显）"; else bad "缺少 set +x"; fi

# 不得出现真实的 crumb 抓取/发送（注释里说明「不用 crumb」不算）。
if grep -qE 'crumbIssuer|Jenkins-Crumb|crumb=' "$CLI"; then
  bad "检测到 crumb 调用，违反「不用 crumb 作为首选」"
else
  ok "未使用 crumb 调用"
fi

# 凭据不得硬编码：Authorization 必须是 %s 占位，不能是字面 base64 串。
if grep -qE 'Authorization: Basic [A-Za-z0-9+/=]{8,}' "$CLI"; then
  bad "疑似硬编码 Basic 凭据"
else
  ok "Basic 凭据由运行时变量注入，未硬编码"
fi

# 文档口径：必须标「运行时确认」，且不得把 consoleText 写成官方文档规定。
if grep -q '运行时确认' "$DOC"; then ok "文档标注「运行时确认」"; else bad "文档缺少「运行时确认」标注"; fi
if grep -qE '官方文档规定.*consoleText|consoleText.*官方文档规定' "$DOC"; then
  bad "文档把 consoleText 写成官方文档规定"
else
  ok "未把 consoleText 冒充官方文档规定"
fi

if (( fail )); then
  echo "jenkins-cli.sh 自检失败" >&2
  exit 1
fi
echo "jenkins-cli.sh 自检通过"
