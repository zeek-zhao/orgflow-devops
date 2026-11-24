#!/bin/sh
# 镜像内健康检查：dig 本地 dnsmasq（真叠加内容）
set -e
dig @127.0.0.1 org-devops.com +short +time=2 +tries=1 >/dev/null 2>&1
