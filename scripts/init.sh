#!/usr/bin/env bash
# #140：deploy 之后的一键收尾。把「LDAP 目录初始化 → 推 Jenkins Job → 起 Nexus」
# 串成一条可复现的命令；每一步都复用已有 Makefile 目标/脚本，不复制实现。
#
# 为什么单独一条而不是并进 deploy：hosts / CA 要动宿主 root 边界，Jenkins
# healthy 也晚于 compose 侧自检；init 单独一条，失败时能明确指出卡在哪一步。
# 为什么 Nexus 只检测不自动部署：#46 的契约是「Nexus 由 Jenkins job 部署」，
# 脚本自动绕过 job 会破坏这条验收，且需要额外的管理员口令环境变量。
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

ENV_FILE="${ENV_FILE:-.env}"
COMPOSE="${COMPOSE:-docker compose}"

if [ ! -f "$ENV_FILE" ]; then
  echo "✗ 缺少 $ENV_FILE；先复制 .env.example 并填写，再跑 USE_GHCR=1 make deploy" >&2
  exit 1
fi

GATEWAY_DOMAIN="$(sed -n 's/^GATEWAY_DOMAIN=//p' "$ENV_FILE" | tail -1 | tr -d '"'"'"'')"
GATEWAY_DOMAIN="${GATEWAY_DOMAIN:-org-devops.com}"
read -r -a compose_cmd <<< "$COMPOSE"
# 下面两个阶段交给 Makefile 自己算 COMPOSE（USE_GHCR 会追加 -f 覆盖层）。
# 若把上面的 COMPOSE 字符串传进子进程，make 的 `?=` 会保留它再追加一次 -f，
# 变成重复覆盖层；这里显式清掉，嵌套 make 用仓库默认的那一份。
unset COMPOSE

# 阶段 0：compose 栈必须已起且全部 healthy（Nexus 不在 compose，见 #46）。
healthy="$("${compose_cmd[@]}" --env-file "$ENV_FILE" ps --format '{{.Health}}' 2>/dev/null \
  | grep -c '^healthy$' || true)"
total="$("${compose_cmd[@]}" --env-file "$ENV_FILE" ps --format '{{.Name}}' 2>/dev/null \
  | wc -l | tr -d ' ')"
if [ "$total" -eq 0 ] || [ "$healthy" -ne "$total" ]; then
  echo "✗ compose 侧 healthy $healthy/$total；先跑 USE_GHCR=1 make deploy，再回来 make init" >&2
  "${compose_cmd[@]}" --env-file "$ENV_FILE" ps
  exit 1
fi
echo "✓ compose 栈 healthy：$healthy/$total"

# 阶段 1：域名解析与 CA 只自检提示（涉及宿主 root，不代做）。
if ! getent hosts "jenkins.${GATEWAY_DOMAIN}" >/dev/null 2>&1; then
  echo "⚠ 本机解析不到 jenkins.${GATEWAY_DOMAIN}：部署机跑 make hosts（要 root），"
  echo "  使用方机器把 scripts/gen-hosts.sh 生成的片段加进各自 hosts"
fi
if [ ! -f out/ca/root.crt ]; then
  echo "⚠ 缺少 out/ca/root.crt：跑 make ca 导出/安装内部 CA（要 root）"
fi

# 阶段 2 / 3：复用 Makefile 目标，避免在脚本里复制命令。
echo "== 1/2 LDAP 目录初始化（bootstrap 幂等 + 口令同步）=="
ENV_FILE="$ENV_FILE" make --no-print-directory ldap-init
echo "== 2/2 推送 Jenkins Job（16 个参数化 Job）=="
ENV_FILE="$ENV_FILE" make --no-print-directory jobs

# 阶段 4：Nexus 由 Jenkins job 部署（#46），这里只检测并给入口。
if docker ps --format '{{.Names}} {{.Health}}' | grep -q '^of-nexus healthy$'; then
  echo "✓ Nexus 已在运行"
else
  echo "⚠ Nexus 尚未运行：在 Jenkins 跑 job nexus-deploy（#46），或 bash scripts/nexus-deploy.sh"
fi

# 阶段 5：入口与账号位置清单。口令只在部署机 .env，绝不打印真值。
echo "== 完成：入口清单 =="
printf '  统一入口   https://home.%s/\n' "$GATEWAY_DOMAIN"
printf '  Jenkins    https://jenkins.%s/\n' "$GATEWAY_DOMAIN"
printf '  Nexus      https://nexus.%s/\n' "$GATEWAY_DOMAIN"
printf '  LDAP Admin https://ldapadmin.%s/\n' "$GATEWAY_DOMAIN"
printf '  账号口令   %s（LDAP 初始口令、各服务管理口令，只在部署机）\n' "$ENV_FILE"
echo "下一步验收：Jenkins 跑 verify-service job；Windows 跑 tools/win-acceptance/Test-OrgflowAcceptance.ps1"
