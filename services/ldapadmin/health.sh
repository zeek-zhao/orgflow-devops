#!/bin/sh
# 镜像内健康检查：本地根路径探活（真叠加内容）
set -e
wget -q -O - http://127.0.0.1/ >/dev/null 2>&1
