#!/usr/bin/env bash
# gerrit-reindex.sh —— M3.0 全量重建后的 Gerrit 索引重建（index 为匿名卷，重建后必须 reindex）
# 背景：Gerrit 官方镜像的 index/db/cache 是匿名卷，compose down+up 后会换成新空卷；
#       NoteDb（git 卷内）是权威数据，完整保留；index 是可再生搜索索引，需重建。
# 用法: bash scripts/gerrit-reindex.sh
#   会停 gerrit → 对其当前 index 卷做全量 reindex → 启动 gerrit（不 recreate，避免换卷）。
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"
CONTAINER="${CONTAINER_PREFIX:-of}-gerrit"
IMG="${GERRIT_IMAGE:-ghcr.io/zeek-zhao/orgflow-devops/m2-gerrit:ctx-547cec6a8cd0}"

echo "[reindex] Gerrit 容器: $CONTAINER"
IDX="$(docker inspect "$CONTAINER" --format '{{range .Mounts}}{{if eq .Destination "/var/gerrit/index"}}{{.Name}}{{end}}{{end}}' 2>/dev/null)"
if [ -z "$IDX" ]; then echo "✗ 找不到 $CONTAINER 的 index 卷（容器可能未创建）" >&2; exit 1; fi
echo "[reindex] index 卷: $IDX"

echo "[reindex] 停 gerrit（保留卷）"
docker compose --env-file config/defaults.env -p "${COMPOSE_PROJECT:-orgflow}-gerrit" -f services/gerrit/compose.yml down >/dev/null 2>&1 || true

echo "[reindex] 清空旧索引（含残留 write.lock / 半写 segment）"
IDXP="$(docker volume inspect "$IDX" --format '{{.Mountpoint}}')"
find "$IDXP" -mindepth 1 -delete 2>/dev/null || true

echo "[reindex] 全量 reindex（NoteDb 为数据源）"
timeout 300 docker run --rm \
  -v orgflow-minimal_gerrit_git:/var/gerrit/git \
  -v orgflow-minimal_gerrit_etc:/var/gerrit/etc \
  -v "$IDX":/var/gerrit/index \
  --entrypoint java \
  "$IMG" \
  -jar /var/gerrit/bin/gerrit.war reindex -d /var/gerrit 2>&1 \
  | grep -iE "Reindexed|ready|Exception|error" | tail -12

echo "[reindex] 启动 gerrit（docker start，不 recreate，避免换匿名卷）"
docker start "$CONTAINER" >/dev/null 2>&1
echo "✓ Gerrit 索引重建完成；验证: docker ps | grep gerrit（healthy）"
