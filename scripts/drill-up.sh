#!/usr/bin/env bash
# drill-up.sh —— M3.0.1 T3 隔离恢复真起栈：从备份解包数据起独立栈（orgflow-drill），验证备份能"把服务跑起来"。
#
# 流程：
#   1) 起栈前跑 quota-guard --preflight，verdict 必须 PASS（记录四项资源）；
#   2) 复用 restore.sh 解包逻辑到 /data/drill/orgflow-drill（只读生产，不动生产容器）；
#   3) 独立 compose project orgflow-drill + 独立网络 172.31.90.0/24 起 gerrit/cgit/ldap 三容器；
#   4) 等 healthy，起栈后 --compare-preflight 确认宿主资源未变；
#   5) 四项断言：cgit 200 + 仓库数3 / gerrit version 3.9.x / changes 与生产一致 / ldap 绑定 OK；
#   6) 全过输出 DRILL PASS。
# 用法: bash scripts/drill-up.sh [备份目录]（默认 latest）
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"
BACKUP="${1:-}"
DRILL="/data/drill/orgflow-drill"
CDIR="$REPO/deploy/drill"
LOG="/data/drill-logs/$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$LOG" "$(dirname "$DRILL")" && : > "$LOG/drill-up.log"
exec > >(tee -a "$LOG/drill-up.log") 2>&1

fail() { echo "✗ DRILL FAIL: $*"; echo "DRILL FAIL $*" > /data/drill/drill.result; exit 1; }
trap 'rc=$?; [ "$rc" -ne 0 ] && echo "DRILL FAIL (rc=$rc)" > /data/drill/drill.result || true' EXIT

echo "=== T3 隔离恢复演练开始 $(date -u +%FT%TZ) ==="
START=$(date +%s)
echo "[drill] backup=${BACKUP:-latest} drill=$DRILL log=$LOG"

# ---- 1) 资源守卫前置 ----
echo "--- [1/5] quota-guard --preflight ---"
bash scripts/quota-guard.sh --container of-builder --out artifacts/quota --preflight || fail "quota preflight 执行失败"
pre="$(python3 -c 'import json;print(json.load(open("artifacts/quota/host-preflight.json")).get("verdict"))' 2>/dev/null || echo MISSING)"
echo "[drill] preflight verdict=$pre"
[ "$pre" = "PASS" ] || fail "quota preflight verdict=$pre != PASS"

# ---- 2) 解包（复用 restore.sh，VERIFY=0 仅解包不比对）----
echo "--- [2/5] restore.sh 解包到 $DRILL ---"
rm -rf "$DRILL"; mkdir -p "$DRILL"
# restore.sh 只解析 $1/$2，用环境变量传参确保 VERIFY=0 生效（drill 起栈不做生产比对）。
if [ -n "$BACKUP" ]; then
  VERIFY=0 PROJECT=orgflow-drill BACKUP="$BACKUP" bash scripts/restore.sh || fail "restore 解包失败"
else
  VERIFY=0 PROJECT=orgflow-drill bash scripts/restore.sh || fail "restore 解包失败"
fi
for d in gerrit_git gerrit_etc ldap_data ldap_config; do
  [ -d "$DRILL/$d" ] || fail "解包缺目录 $d"
done
echo "[drill] 解包目录: $(find "$DRILL" -maxdepth 1 -type d -printf '%f ' )"
REPOS=$(find "$DRILL/gerrit_git" -maxdepth 1 -name '*.git' -type d 2>/dev/null | wc -l)
echo "[drill] gerrit_git 仓库数=$REPOS"
[ "$REPOS" = "3" ] || fail "仓库数=$REPOS != 3"

# ---- 2b) Gerrit index 重建（备份不含可再生索引，NoteDb 为数据源）----
# 这正是 T6 要根治的手工步骤：演练中按 M3.0 既有口径，起栈前先 reindex 到 bind 目录。
echo "--- [2b] Gerrit 全量 reindex（NoteDb→index）---"
mkdir -p "$DRILL/gerrit_index"
# gerrit 容器内 uid=1000，index 目录须属主 1000 才能写入（解包 git/etc 已保留 1000:1000）。
chown -R 1000:1000 "$DRILL/gerrit_index" 2>/dev/null || true
# 用 compose 期望的 ghcr.io ctx tag（本地已就绪，避免 orgflow/* 本地名触发 docker.io 拉取）。
GIMG="ghcr.io/zeek-zhao/orgflow-devops/m2-gerrit:ctx-547cec6a8cd0"
docker run --rm \
  -v "$DRILL/gerrit_git:/var/gerrit/git" \
  -v "$DRILL/gerrit_etc:/var/gerrit/etc" \
  -v "$DRILL/gerrit_index:/var/gerrit/index" \
  --entrypoint java "$GIMG" \
  -jar /var/gerrit/bin/gerrit.war reindex -d /var/gerrit 2>&1 \
  | grep -iE 'Reindexed|ready|Exception|error' | tail -8 || fail "gerrit reindex 失败"
echo "[drill] gerrit index 重建完成"

# ---- 3) 起独立栈 ----
echo "--- [3/5] 起独立栈 orgflow-drill ---"
# 网络由 compose 按 172.31.90.0/24 自行创建（带 project 标签）；若上次残留无标签网络先删掉。
if docker network inspect orgflow-drill_net >/dev/null 2>&1; then
  docker network rm orgflow-drill_net >/dev/null 2>&1 || true
fi
docker compose --env-file config/defaults.env -f "$CDIR/compose.yml" up -d --no-build || fail "compose up 失败"
# 等 healthy（最多 180s）
echo "[drill] 等待容器 healthy ..."
for i in $(seq 1 60); do
  states="$(docker compose -f "$CDIR/compose.yml" ps --format '{{.Name}}={{.Status}}' 2>/dev/null | tr '\n' ' ')"
  hc="$(printf '%s' "$states" | grep -o 'healthy' | wc -l)"
  [ "$hc" -ge 3 ] && { echo "[drill] 三容器 healthy（${i}次轮询）: $states"; break; }
  sleep 3
done
docker compose -f "$CDIR/compose.yml" ps || fail "容器未全部 healthy"

# 起栈后比对宿主资源未变
bash scripts/quota-guard.sh --container of-builder --out artifacts/quota --compare-preflight artifacts/quota/host-preflight.json 2>&1 | tail -4 || true

# ---- 4) 四项断言 ----
echo "--- [4/5] 四项断言 ---"
assertrc=0
# a) cgit 200
code=$(curl -s --noproxy '*' -o /tmp/drill_cgit.html -w '%{http_code}' http://127.0.0.1:18089/ || echo 000)
echo "[assert a] cgit / HTTP=$code"
[ "$code" = "200" ] || { echo "✗ cgit 非 200"; assertrc=1; }
# 仓库数（页面出现的业务仓列表 orgflow-devops）
repos_page=$(grep -o 'orgflow-devops' /tmp/drill_cgit.html 2>/dev/null | head -1)
[ -n "$repos_page" ] && echo "[assert a] cgit 页面列出业务仓 orgflow-devops" || { echo "✗ cgit 页面无业务仓"; assertrc=1; }

# b) gerrit version 3.9.x
gver=$(curl -sL --noproxy '*' http://127.0.0.1:18443/config/server/version 2>/dev/null | tr -d '\r\n' | head -c 40)
echo "[assert b] gerrit version=$gver"
printf '%s' "$gver" | grep -qE '3\.9\.' || { echo "✗ gerrit version 非 3.9.x"; assertrc=1; }

# c) changes 与生产一致（生产当前 open=0）
gchanges=$(curl -sL --noproxy '*' 'http://127.0.0.1:18443/changes/?q=status:open' 2>/dev/null | sed '1s/^)]}'"'"'//' | jq 'length' 2>/dev/null || echo ERR)
echo "[assert c] drill open changes=$gchanges"
[ "$gchanges" = "0" ] || { echo "✗ drill open changes=$gchanges != 0"; assertrc=1; }

# d) ldap 绑定（在 drill 容器内验证，不暴露宿主端口）
ldap_ok=$(docker exec drill-ldap sh -c 'printf "change-me" | ldapwhoami -x -H ldap://127.0.0.1 -D "cn=admin,dc=orgflow,dc=local" -y /dev/stdin >/dev/null 2>&1; echo $?' 2>/dev/null || echo 1)
echo "[assert d] ldap bind rc=$ldap_ok"
[ "$ldap_ok" = "0" ] || { echo "✗ ldap 绑定失败 rc=$ldap_ok"; assertrc=1; }

[ "$assertrc" -eq 0 ] || fail "四项断言有失败（rc=$assertrc）"

# ---- 5) 收尾 ----
echo "--- [5/5] 清理 drill 栈（保留解包数据与日志）---"
bash scripts/drill-down.sh 2>&1 | tail -5 || true
echo "DRILL PASS total_elapsed=$(( $(date +%s) - START ))s"
echo "DRILL PASS" > /data/drill/drill.result
echo "=== T3 隔离恢复演练结束 $(date -u +%FT%TZ) ==="
