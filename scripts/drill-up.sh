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

# D5（M3.0.2）：LDAP 口令从 LDAP_PASSWORD 环境或口令文件读，禁止脚本内写死。
LDAP_PWFILE="${LDAP_PASSWORD_FILE:-/opt/orgflow/secrets/ldap_admin_password}"
LDAP_PASSWORD=""
if [ -n "${LDAP_PASSWORD_ENV:-${LDAP_PASSWORD:-}}" ]; then
  LDAP_PASSWORD="${LDAP_PASSWORD_ENV:-$LDAP_PASSWORD}"
elif [ -f "$LDAP_PWFILE" ]; then
  LDAP_PASSWORD="$(cat "$LDAP_PWFILE" 2>/dev/null | tr -d '\r\n')"
fi
if [ -z "$LDAP_PASSWORD" ]; then
  echo "[drill] ✗ LDAP 口令缺失：请设 LDAP_PASSWORD 环境或写 $LDAP_PWFILE（chmod 600）"
  echo "{\"result\":\"FAIL\",\"ts\":\"$(basename "$LOG")\",\"backup\":\"${BACKUP:-latest}\",\"log\":\"$LOG\",\"note\":\"ldap-password-missing\"}" > /data/drill/drill.result
  exit 2
fi
export LDAP_PASSWORD
echo "[drill] LDAP 口令已从 $([ -n "${LDAP_PASSWORD_ENV:-${LDAP_PASSWORD:-}}" ] && echo 环境 || echo "$LDAP_PWFILE") 读取（不回显）"

# D5（M3.0.2）：镜像 tag 从 config/images.env 的 IMAGE_GERRIT 解析，禁止硬编码 ctx-547cec6a8cd0。
# images.env 是本地构建名 orgflow/m2-gerrit:<tag>；本地已备 ghcr.io 同 tag，拼成 ghcr 路径避免 docker.io 拉取。
GERRIT_TAG="$(grep '^IMAGE_GERRIT=' "$REPO/config/images.env" | cut -d= -f2- | awk -F: '{print $NF}')"
if [ -z "$GERRIT_TAG" ]; then
  echo "[drill] ✗ 无法从 config/images.env 解析 IMAGE_GERRIT tag"
  echo "{\"result\":\"FAIL\",\"ts\":\"$(basename "$LOG")\",\"backup\":\"${BACKUP:-latest}\",\"log\":\"$LOG\",\"note\":\"gerrit-tag-missing\"}" > /data/drill/drill.result
  exit 2
fi
GIMG="ghcr.io/zeek-zhao/orgflow-devops/m2-gerrit:$GERRIT_TAG"
echo "[drill] gerrit 镜像 tag=$GERRIT_TAG（来自 config/images.env）"

# D4（M3.0.2）：drill.result 改 JSON {"result":"PASS|FAIL","ts":"...","backup":"...","log":"..."}
# ts 用本次日志目录名（UTC），供 verify-restore-drill 做 result/log 同源（≤10min）判定。
write_result() {
  local result="$1" note="${2:-}"
  python3 - "$result" "$(basename "$LOG")" "${BACKUP:-latest}" "$LOG" "$note" <<'PY'
import json,sys,os
result,logdir,backup,log,notes=sys.argv[1:6]
d={"result":result,"ts":logdir,"backup":backup,"log":log}
if notes: d["note"]=notes
p="/data/drill/drill.result"
tmp=p+".tmp"; json.dump(d,open(tmp,'w',encoding='utf-8'),ensure_ascii=False,indent=2); os.replace(tmp,p)
PY
}

fail() { echo "✗ DRILL FAIL: $*"; write_result "FAIL" "$*"; exit 1; }
trap 'rc=$?; [ "$rc" -ne 0 ] && write_result "FAIL" "exit rc=$rc" || true' EXIT

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

# D5 修复：server_id 单一真源 = 生产 etc 卷的 server_id 文件。解包的 gerrit_etc 若缺该文件，
# entrypoint 在 set -u 下会因 GERRIT_SERVER_ID 未定义而退出（GERRIT_SERVER_ID: unbound variable）。
# 从生产卷复制到解包 etc（不改源码/不硬编码），保证 drill gerrit 与生产 serverId 一致（NoteDb 兼容）。
PROD_ETC="$(docker inspect of-gerrit --format '{{range .Mounts}}{{if eq .Destination "/var/gerrit/etc"}}{{.Source}}{{end}}{{end}}' 2>/dev/null)"
if [ -n "$PROD_ETC" ] && [ -s "$PROD_ETC/server_id" ]; then
  cp "$PROD_ETC/server_id" "$DRILL/gerrit_etc/server_id"
  chown 1000:1000 "$DRILL/gerrit_etc/server_id" 2>/dev/null || true
  chmod 600 "$DRILL/gerrit_etc/server_id" 2>/dev/null || true
  echo "[drill] server_id 已从生产卷复制到解包 etc（$(cat "$DRILL/gerrit_etc/server_id")）"
else
  echo "[drill] ⚠ 生产 server_id 不可用，drill gerrit 可能无法启动"
fi

# ---- 2b) Gerrit index 重建（备份不含可再生索引，NoteDb 为数据源）----
# 这正是 T6 要根治的手工步骤：演练中按 M3.0 既有口径，起栈前先 reindex 到 bind 目录。
echo "--- [2b] Gerrit 全量 reindex（NoteDb→index）---"
mkdir -p "$DRILL/gerrit_index"
# gerrit 容器内 uid=1000，index 目录须属主 1000 才能写入（解包 git/etc 已保留 1000:1000）。
chown -R 1000:1000 "$DRILL/gerrit_index" 2>/dev/null || true
# 用 config/images.env 解析出的 ghcr.io tag（本地已就绪，避免 orgflow/* 本地名触发 docker.io 拉取）。
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
# D5 修复：起栈前只清理上次失败残留的 drill 容器/网络（避免复用旧容器导致 cgit 404 假失败）。
# 注意：绝不能调用 drill-down.sh —— 它删 /data/drill/orgflow-drill 解包数据（本脚本上面刚解包好）。
docker compose --env-file config/defaults.env -f "$CDIR/compose.yml" down -v --remove-orphans >/dev/null 2>&1 || true
if docker network inspect orgflow-drill_net >/dev/null 2>&1; then
  docker network rm orgflow-drill_net >/dev/null 2>&1 || true
fi
docker compose --env-file config/defaults.env -f "$CDIR/compose.yml" up -d --no-build || fail "compose up 失败"
# 等 healthy（最多 450s；gerrit healthcheck start_period=90s + interval=15s，冷启动偏慢）
echo "[drill] 等待容器 healthy（最多 450s）..."
for i in $(seq 1 150); do
  states="$(docker compose -f "$CDIR/compose.yml" ps --format '{{.Name}}={{.Status}}' 2>/dev/null | tr '\n' ' ')"
  hc="$(printf '%s' "$states" | grep -o 'healthy' | wc -l)"
  if [ "$hc" -ge 3 ]; then
    echo "[drill] 三容器 healthy（${i}次轮询，约 $((i*3))s）: $states"
    break
  fi
  # 每 30s 打印一次进度，便于观察慢启动的 gerrit（health: starting 阶段不计入 healthy）
  [ $((i % 10)) -eq 0 ] && echo "[drill] 等待中 $((i*3))s: $states"
  sleep 3
done
# D5（M3.0.2）：等待循环结束后强制断言 healthy 容器数为 3，否则 FAIL（指出 unhealthy 容器名 + gerrit 日志尾）。
states="$(docker compose -f "$CDIR/compose.yml" ps --format '{{.Name}}={{.Status}}' 2>/dev/null | tr '\n' ' ')"
hc="$(printf '%s' "$states" | grep -o 'healthy' | wc -l)"
echo "[drill] healthy 数=$hc（要求=3）states=$states"
if [ "$hc" -ne 3 ]; then
  echo "[drill] --- drill-gerrit 日志尾（诊断慢启动/启动失败）---"
  docker logs --tail 30 drill-gerrit 2>&1 | tail -30 || true
  fail "healthy 容器数=$hc != 3（unhealthy: $(printf '%s' "$states" | tr ' ' '\n' | grep -v healthy | tr '\n' ' ')）"
fi
docker compose -f "$CDIR/compose.yml" ps || fail "容器未全部 healthy"

# 起栈后比对宿主资源未变
bash scripts/quota-guard.sh --container of-builder --out artifacts/quota --compare-preflight artifacts/quota/host-preflight.json 2>&1 | tail -4 || true

# ---- 4) 四项断言 ----
echo "--- [4/5] 四项断言 ---"
assertrc=0
# a) cgit 200（nginx healthy 后页面可能仍需短暂就绪，重试最多 5 次）
code=000
for i in $(seq 1 5); do
  code=$(curl -s --noproxy '*' -o /tmp/drill_cgit.html -w '%{http_code}' http://127.0.0.1:18089/ || echo 000)
  [ "$code" = "200" ] && break
  sleep 2
done
echo "[assert a] cgit / HTTP=$code"
[ "$code" = "200" ] || { echo "✗ cgit 非 200"; assertrc=1; }
# 仓库数（页面出现的业务仓列表 orgflow-devops）
repos_page=$(grep -o 'orgflow-devops' /tmp/drill_cgit.html 2>/dev/null | head -1)
[ -n "$repos_page" ] && echo "[assert a] cgit 页面列出业务仓 orgflow-devops" || { echo "✗ cgit 页面无业务仓"; assertrc=1; }

# b) gerrit version 3.9.x
gver=$(curl -sL --noproxy '*' http://127.0.0.1:18443/config/server/version 2>/dev/null | tr -d '\r\n' | head -c 40)
echo "[assert b] gerrit version=$gver"
printf '%s' "$gver" | grep -qE '3\.9\.' || { echo "✗ gerrit version 非 3.9.x"; assertrc=1; }

# c) changes 与生产实时对比（D5）：先取生产 open changes 数 P，再要求 drill 的 D==P；
#    P 取不到直接 FAIL，不得默认 0。用 SSH 查生产（ci-bot），HTTP 查 drill。
SSHOPT="-i $REPO/secrets/gerrit_ci_ssh_key -p 29418 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8"
# 注意：grep -c 无匹配时返回 exit 1，必须用 `|| true` 而非 `|| echo ERR`（否则得到 "0\nERR"）。
P=$( { ssh $SSHOPT ci-bot@127.0.0.1 "gerrit query status:open" 2>/dev/null || true; } | grep -c '^change' || true )
P="$(printf '%s' "$P" | tr -d '\r\n ')"
if ! printf '%s' "$P" | grep -qE '^[0-9]+$'; then
  echo "[assert c] ✗ 生产 open changes 取不到（P=$P），不默认 0，直接 FAIL"
  assertrc=1; P="ERR"
else
  echo "[assert c] 生产 open changes P=$P"
fi
D=$( { curl -sL --noproxy '*' 'http://127.0.0.1:18443/changes/?q=status:open' 2>/dev/null | sed '1s/^)]}'"'"'//' | jq 'length' 2>/dev/null || true; } )
D="$(printf '%s' "$D" | tr -d '\r\n ')"
echo "[assert c] drill open changes D=$D"
if [ "$P" = "ERR" ]; then
  assertrc=1
elif ! printf '%s' "$D" | grep -qE '^[0-9]+$'; then
  echo "✗ drill changes 查询失败 D=$D"; assertrc=1
elif [ "$D" != "$P" ]; then
  echo "✗ drill changes D=$D != 生产 P=$P"; assertrc=1
else
  echo "[assert c] drill 与生产 changes 对齐 P=$P D=$D"
fi

# d) ldap 绑定（在 drill 容器内验证，不暴露宿主端口）
ldap_ok=$(docker exec drill-ldap sh -c 'printf "change-me" | ldapwhoami -x -H ldap://127.0.0.1 -D "cn=admin,dc=orgflow,dc=local" -y /dev/stdin >/dev/null 2>&1; echo $?' 2>/dev/null || echo 1)
echo "[assert d] ldap bind rc=$ldap_ok"
[ "$ldap_ok" = "0" ] || { echo "✗ ldap 绑定失败 rc=$ldap_ok"; assertrc=1; }

[ "$assertrc" -eq 0 ] || fail "四项断言有失败（rc=$assertrc）"

# ---- 5) 收尾 ----
echo "--- [5/5] 清理 drill 栈（保留解包数据与日志）---"
bash scripts/drill-down.sh 2>&1 | tail -5 || true
echo "DRILL PASS total_elapsed=$(( $(date +%s) - START ))s"
write_result "PASS"
echo "=== T3 隔离恢复演练结束 $(date -u +%FT%TZ) ==="
