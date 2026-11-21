#!/usr/bin/env bash
# deploy.sh —— 一键部署（M0 重构后：配置来自 config/，不再有 .env）
#
# 流程（每一步都能单独重跑，全部幂等）：
#   1. 校验配置并渲染 out/runtime.env / Caddyfile / dex 配置   → 10-render-config.sh
#   2. 备好 agent 密钥（缺才生成）与 CA 证书（缺才生成）        → 40-gen-agent-key.sh / 20-gen-ca.sh
#   3. 按 start_order 串行启动，每个服务等到 healthy            → 30-up-serial.sh
#   4. agent 权限复核（su 走 initgroups，与 sshd 等价）
#   5. 端点自检（每层都要有一条：网关/应用/登录页）
#
# 用法：
#   make deploy                    # 整栈（213 上 USE_GHCR=1）
#   bash scripts/50-deploy.sh --service jenkins      # 单服务
#   bash scripts/50-deploy.sh --push-jobs            # 部署后推 Jenkins Job（= make jobs）
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
# shellcheck source=lib/runtime.sh
. "$ROOT/scripts/lib/runtime.sh"

PUSH_JOBS=0
SERVICE=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --push-jobs) PUSH_JOBS=1; shift ;;
    --service)
      [ "$#" -ge 2 ] && [ -n "$2" ] || orgflow_fail "--service 需要指定服务名"
      # 传两次就等于静默丢掉一个：照最后一个跑完，运维以为另一个也部署了
      [ -z "$SERVICE" ] || orgflow_fail "--service 只能指定一个服务（已给 $SERVICE，又给 $2）"
      SERVICE="$2"; shift 2 ;;
    *) orgflow_fail "未知参数: $1" ;;
  esac
done

if [ "$PUSH_JOBS" = 1 ]; then
  [ -z "$SERVICE" ] || orgflow_fail "--push-jobs 不能与 --service 同用"
  exec make jobs
fi

if [ -n "$SERVICE" ]; then
  # --service 只接受 compose 里的服务。orgflow_container 会连 tools/external
  # 一起查，nexus 属于 external（#46 由 job nexus-deploy 用 docker run 拉起），
  # 用它做过判据就会让 `--service nexus` 静默跑通一个"什么都没部署"的成功。
  case " $(orgflow_services | tr '\n' ' ') " in
    *" $SERVICE "*) ;;
    *)
      if [ "$SERVICE" = nexus ]; then
        orgflow_fail "--service nexus 不支持（#46）：nexus 不在 compose 里，由 Jenkins job nexus-deploy 部署（bash scripts/70-nexus-deploy.sh）"
      fi
      orgflow_fail "不支持的服务: $SERVICE（可选值见 config/services.yml 的 services 段，或 make services）"
      ;;
  esac
fi

# 这两个开关在 ADR-13 之后就废弃了。保留成硬错误而不是静默忽略 ——
# 传了却什么都没发生，是排查时最贵的一种"成功"。
[ -z "${SERVICE_VERSION:-}" ] || orgflow_fail "SERVICE_VERSION 已停用（#46）：nexus 移出 compose，改由 Jenkins job nexus-deploy 部署"
[ -z "${SERVICE_PORT:-}" ] || orgflow_fail "SERVICE_PORT 已废弃（ADR-13 域名路由）：改 config/orgflow.yml 的 gateway.http_port / https_port"
[ -z "${SERVICE_DOMAIN:-}" ] || orgflow_fail "SERVICE_DOMAIN 已废弃（ADR-13 域名路由）：改 config/orgflow.yml 的 gateway.domain"

echo "== 1/5 渲染配置 =="
bash scripts/10-render-config.sh
orgflow_load_runtime_env

echo "== 2/5 备齐密钥与证书 =="
bash scripts/40-gen-agent-key.sh >/dev/null
echo "  agent 密钥就绪（secrets/，缺才生成）"
bash scripts/20-gen-ca.sh

echo "== 3/5 串行启动 =="
orgflow_export_runtime_env
if [ -n "$SERVICE" ]; then
  bash scripts/30-up-serial.sh "$SERVICE"
else
  bash scripts/30-up-serial.sh
fi

if [ -z "$SERVICE" ]; then
  echo "== 4/5 agent 权限复核 =="
  # agent 的 SSH 会话用户是 jenkins(1000)（镜像里 PermitRootLogin no）。
  #
  # ★ 必须走 su，不能用 `docker exec -u jenkins ...`：
  #   docker exec 会继承容器 OCI spec 里的 AdditionalGids（group_add 的效果），
  #   而 sshd 给登录会话调 initgroups()、按 /etc/group 重置附加组。
  #   所以 `docker exec -u jenkins docker info` 即使在真机上 job 全挂也照样通过
  #   —— 这个假阳性害我们多花了一轮真机验收（2026-11-01）。
  agent_container="$(orgflow_container jenkins-agent)"
  if ! docker exec "$agent_container" su -s /bin/sh -c 'docker info' jenkins >/dev/null 2>&1; then
    echo "✗ agent 里 jenkins 用户的 SSH 会话连不上 /var/run/docker.sock（DOCKER_GID=${DOCKER_GID:-未设置}）" >&2
    echo "  job 会以「找不到网络 orgflow」这类假象失败。检查：" >&2
    echo "    stat -c %g /var/run/docker.sock                 # 宿主上的真实 gid" >&2
    echo "    docker exec $agent_container id -Gn jenkins     # jenkins 的附加组" >&2
    echo "    docker logs $agent_container | head -20        # 入口脚本有没有改 /etc/group" >&2
    exit 1
  fi
  echo "  ✓ agent 能驱动宿主 docker（gid ${DOCKER_GID:-未设置}，经 su 复核）"

  echo "== 5/5 端点自检 =="
  bash scripts/60-verify-endpoints.sh
fi

echo "== 部署完成 =="
HTTPS_PORT="$(orgflow_py env GATEWAY_HTTPS_PORT)"
if [ "$HTTPS_PORT" = "443" ]; then VISIBLE_PORT=""; else VISIBLE_PORT=":${HTTPS_PORT}"; fi
echo "网关端口：HTTP $(orgflow_py env GATEWAY_HTTP_PORT) / HTTPS ${HTTPS_PORT}（宿主映射）"
echo "访问入口（需要先让域名解析到本机）："
echo "  $(orgflow_py site home)/           统一入口"
echo "  $(orgflow_py site jenkins)/login    Jenkins（LDAP 账号，管理员 $(orgflow_py env JENKINS_ADMIN_ID)）"
echo "  $(orgflow_py site docs)/            在线文档（仅 docs-users 组成员可进）"
echo "  $(orgflow_py site home)  之外的服务入口见该页卡片"
echo "域名解析：bash scripts/80-gen-hosts.sh     证书信任：bash scripts/21-export-ca.sh"
echo "账号口令：config/orgflow.yml（口令真值）+ docs/30-架构/架构图.md（谁用哪个账号）"
echo "下一步: make init（初始化目录账号与 Jenkins Job）"
