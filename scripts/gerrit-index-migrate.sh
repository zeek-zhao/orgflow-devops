#!/usr/bin/env bash
# gerrit-index-migrate.sh —— M3.0.1 T6：Gerrit index 匿名卷 → named volume 迁移（灾备去手工 reindex）
#
# 迁移窗口内 gerrit 停机（目标 ≤2min，脚本记录真实起止）。步骤：
#   1) 记录旧匿名 index 卷来源与开始时间；
#   2) 停 gerrit（compose down，保留卷）；
#   3) 创建 named volume orgflow-minimal_gerrit_index；
#   4) 一次性容器把旧匿名卷 index 内容 cp -a 到新卷（保留 uid1000）；
#   5) compose 起 gerrit（此时 compose 已声明 gerrit_index named volume），等 healthy；
#   6) 计算停机时长，验证无需手工 reindex 即可 healthy。
# 回滚：停 gerrit → 清空新卷 → compose 回退挂载（移除 gerrit_index 段）→ make gerrit-reindex。
# 用法: bash scripts/gerrit-index-migrate.sh
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"
ENVFILE="config/defaults.env"
NEWVOL="$(grep '^GERRIT_INDEX_VOLUME=' "$ENVFILE" | cut -d= -f2-)"
NEWVOL="${NEWVOL:-orgflow-minimal_gerrit_index}"
# D5（M3.0.2）：tag 从 config/images.env 的 IMAGE_GERRIT 解析，禁止硬编码。
# images.env 是本地构建名 orgflow/m2-gerrit:<tag>；拼 ghcr.io 路径用本地已备的同 tag 镜像，避免 docker.io 拉取。
GERRIT_TAG="$(grep '^IMAGE_GERRIT=' config/images.env | cut -d= -f2- | awk -F: '{print $NF}')"
[ -n "$GERRIT_TAG" ] || { echo "✗ 无法从 config/images.env 解析 IMAGE_GERRIT tag"; exit 2; }
GIMG="ghcr.io/zeek-zhao/orgflow-devops/m2-gerrit:$GERRIT_TAG"
echo "[migrate] gerrit 镜像 tag=$GERRIT_TAG（来自 config/images.env）"

echo "=== T6 Gerrit index 迁移开始 $(date -u +%FT%TZ) ==="
T0=$(date +%s)

# 1) 旧匿名 index 卷宿主机路径
OLD_SRC="$(docker inspect of-gerrit --format '{{range .Mounts}}{{if eq .Destination "/var/gerrit/index"}}{{.Source}}{{end}}{{end}}' 2>/dev/null)"
[ -n "$OLD_SRC" ] || { echo "✗ 找不到 of-gerrit 的 index 挂载"; exit 1; }
OLD_VOL="$(docker inspect of-gerrit --format '{{range .Mounts}}{{if eq .Destination "/var/gerrit/index"}}{{.Name}}{{end}}{{end}}' 2>/dev/null)"
echo "[migrate] 旧 index: vol=${OLD_VOL:-<anonymous>} src=$OLD_SRC"
echo "[migrate] 新 index: $NEWVOL"

# 2) 停 gerrit（compose down 保留卷）
echo "[migrate] 停 gerrit（compose down，保留卷）"
docker compose --env-file "$ENVFILE" -p orgflow-gerrit -f services/gerrit/compose.yml down >/dev/null 2>&1 || true

# 3) 创建 named volume（若不存在）
if ! docker volume inspect "$NEWVOL" >/dev/null 2>&1; then
  docker volume create "$NEWVOL" >/dev/null
  echo "[migrate] ✓ 建卷 $NEWVOL"
else
  echo "[migrate] 卷 $NEWVOL 已存在"
fi

# 4) 一次性容器 cp -a 旧 index 内容到新卷（跳过 write.lock / 半写段）
# 注意：新卷默认 root:root，必须以 root 执行 cp/chown，否则 gerrit(uid1000) 无权写入导致静默失败。
echo "[migrate] cp -a 旧 index → 新卷"
docker run --rm --user root \
  -v "$OLD_SRC:/old:ro" \
  -v "$NEWVOL:/new" \
  --entrypoint sh "$GIMG" -c '
    set -e
    find /new -mindepth 1 -delete 2>/dev/null || true
    cp -a /old/. /new/
    find /new -name "write.lock" -delete 2>/dev/null || true
    chown -R 1000:1000 /new
    echo "[migrate] copied $(find /new -type f | wc -l) files"
  ' || { echo "✗ index 拷贝失败"; exit 1; }

# 5) 起 gerrit（compose 已声明 gerrit_index），等 healthy
echo "[migrate] 起 gerrit（带 named index volume，不执行 reindex）"
docker compose --env-file "$ENVFILE" -p orgflow-gerrit -f services/gerrit/compose.yml up -d --no-build --no-deps gerrit >/dev/null 2>&1 || docker compose --env-file "$ENVFILE" -p orgflow-gerrit -f services/gerrit/compose.yml up -d --no-build gerrit >/dev/null 2>&1 || { echo "✗ gerrit 起栈失败"; exit 1; }
OK=0
for i in $(seq 1 30); do
  st="$(docker inspect of-gerrit --format '{{.State.Health.Status}}' 2>/dev/null || echo missing)"
  [ "$st" = "healthy" ] && { OK=1; echo "[migrate] gerrit healthy（第 ${i} 次轮询）"; break; }
  sleep 2
done
T1=$(date +%s)
DOWN=$(( T1 - T0 ))
echo "[migrate] 停机窗口=$DOWN s（起止 $(date -u -d @$T0 +%FT%TZ) → $(date -u -d @$T1 +%FT%TZ)）"
[ "$OK" -eq 1 ] || { echo "✗ gerrit 未 healthy（未手工 reindex）"; exit 1; }
[ "$DOWN" -le 120 ] || { echo "✗ 停机 $DOWN s >120s"; exit 1; }

# 6) 验证 index 卷已切换、无需 reindex
NEW_SRC="$(docker inspect of-gerrit --format '{{range .Mounts}}{{if eq .Destination "/var/gerrit/index"}}{{.Source}}{{end}}{{end}}' 2>/dev/null)"
echo "[migrate] 新 index source=$NEW_SRC"
printf '%s' "$NEW_SRC" | grep -q "$NEWVOL" || { echo "✗ gerrit 未挂载新 named volume"; exit 1; }
echo "✓ T6 迁移完成：gerrit healthy、index=named volume、停机 ${DOWN}s、未手工 reindex"
