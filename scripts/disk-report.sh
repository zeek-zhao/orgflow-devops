#!/usr/bin/env bash
# disk-report.sh —— M3.0 容量报告（只读）：磁盘水位 + 可清理镜像 + 旧构建 + artifacts 大小
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "=== [disk-report] 磁盘水位 ==="
df -h / 2>/dev/null | tail -n +1

echo
echo "=== [disk-report] Docker 空间概览 ==="
docker system df 2>&1 || true

echo
echo "=== [disk-report] 在用镜像 tag（当前运行容器，不可清理）==="
docker ps --format '{{.Image}}' | sort -u | sed 's/^/  IN_USE /'

echo
echo "=== [disk-report] dangling 镜像（可安全清理）==="
DANGLING="$(docker images -f dangling=true --format '{{.ID}}\t{{.Size}}' 2>/dev/null)"
if [ -n "$DANGLING" ]; then
  echo "$DANGLING" | sed 's/^/  PRUNABLE /'
  n=$(echo "$DANGLING" | wc -l); echo "  合计 $n 个 dangling 镜像"
else
  echo "  (无)"
fi

echo
echo "=== [disk-report] 非在用 tag 镜像（候选，需人工确认，不自动删）==="
INUSE="$(docker ps --format '{{.Image}}' | sort -u)"
docker images --format '{{.Repository}}:{{.Tag}}\t{{.Size}}' 2>/dev/null \
  | grep -v '<none>' \
  | while IFS=$'\t' read -r img sz; do
      echo "$INUSE" | grep -qxF "$img" || echo "  CANDIDATE $img  $sz"
    done | head -40

echo
echo "=== [disk-report] 旧构建 / artifacts ==="
echo "  artifacts/quota: $(du -sh "$REPO/artifacts/quota" 2>/dev/null | awk '{print $1}')"
echo "  artifacts 合计:  $(du -sh "$REPO/artifacts" 2>/dev/null | awk '{print $1}')"
echo "  backups:         $(du -sh /data/backups 2>/dev/null | awk '{print $1}' || echo 缺失)"
echo "  Jenkins 旧构建数（构建目录）:"
docker exec of-jenkins sh -c 'find /var/jenkins_home/jobs -type d -name "builds" -exec sh -c "find \"\$1\" -maxdepth 1 -mindepth 1 -type d | wc -l" _ {} \; 2>/dev/null | awk "{s+=\$1} END{print s+0}"' 2>/dev/null || echo "  (读取失败)"
