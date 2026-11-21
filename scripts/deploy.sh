#!/usr/bin/env bash
# 占位文件：M0 重构后部署入口是 scripts/50-deploy.sh。
#
# 为什么保留而不是直接删：旧文档、旧习惯、外部流水线里可能还写着
# `bash scripts/deploy.sh`。直接删掉会报「No such file」——看起来像仓库坏了；
# 留一条说明清楚的失败信息，下一个人能自己找到新入口。
#
# 旧脚本的三件事现在分别由这些负责：
#   - 生成/迁移 .env      → config/orgflow.yml（人写）+ scripts/10-render-config.sh（渲染）
#   - 一次性起 10 个服务   → scripts/30-up-serial.sh（按 config/services.yml 的 start_order 串行）
#   - 端点自检            → scripts/60-verify-endpoints.sh（三层：容器内 / 宿主端口 / 域名）
set -euo pipefail

cat >&2 <<'MSG'
✗ scripts/deploy.sh 已在 M0 重构中退役（配置单一源 + 按服务拆分 compose + 串行启动）。

  部署请用：
    make deploy                     # = scripts/50-deploy.sh（渲染 → 密钥/CA → 串行起 → 三层自检）
    make deploy SERVICE=ldap        # 只重建一个服务
    bash scripts/50-deploy.sh       # 不经 make 的等价入口

  配置在 orgflow.yml（唯一人工维护的文件），渲染产物是 out/runtime.env。
MSG
exit 1
