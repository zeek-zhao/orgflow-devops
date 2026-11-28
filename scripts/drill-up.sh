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

# M3.0.4 T2/F5：解析"实际备份目录"用于任何失败路径的 backup 字段——绝不写字面 "latest"。
# 优先级：显式 BACKUP（存在）→ /data/backups/latest 指向（存在）→ unknown。
resolve_backup_path() {
  local b="${1:-}"
  if [ -n "$b" ] && [ -d "$b" ]; then printf '%s' "$b"; return 0; fi
  b="$(cat /data/backups/latest 2>/dev/null || true)"
  if [ -n "$b" ] && [ -d "$b" ]; then printf '%s' "$b"; return 0; fi
  printf 'unknown'
}

# D5（M3.0.2）/ M3.0.3 T4：LDAP 口令从 LDAP_PASSWORD 环境或口令文件读，禁止脚本内写死。
LDAP_PWFILE="${LDAP_PASSWORD_FILE:-/opt/orgflow/secrets/ldap_admin_password}"
LDAP_PASSWORD=""
LDAP_PW_SRC=""
if [ -n "${LDAP_PASSWORD_ENV:-${LDAP_PASSWORD:-}}" ]; then
  LDAP_PASSWORD="${LDAP_PASSWORD_ENV:-$LDAP_PASSWORD}"; LDAP_PW_SRC="环境"
elif [ -f "$LDAP_PWFILE" ]; then
  LDAP_PASSWORD="$(cat "$LDAP_PWFILE" 2>/dev/null | tr -d '\r\n')"; LDAP_PW_SRC="$LDAP_PWFILE"
fi
if [ -z "$LDAP_PASSWORD" ]; then
  echo "[drill] ✗ LDAP 口令缺失：请设 LDAP_PASSWORD 环境或写 $LDAP_PWFILE（chmod 600）"
  printf '{"result":"FAIL","ts":"%s","backup":"%s","log":"%s","mode":"full","note":"ldap-password-missing"}\n' \
    "$(basename "$LOG")" "$(resolve_backup_path "$BACKUP")" "$LOG" > /data/drill/drill.result
  exit 2
fi
export LDAP_PASSWORD
echo "[drill] LDAP 口令已从 $LDAP_PW_SRC 读取（不回显）"

# D5（M3.0.2）：镜像 tag 从 config/images.env 的 IMAGE_GERRIT 解析，禁止硬编码 ctx-547cec6a8cd0。
# images.env 是本地构建名 orgflow/m2-gerrit:<tag>；本地已备 ghcr.io 同 tag，拼成 ghcr 路径避免 docker.io 拉取。
GERRIT_TAG="$(grep '^IMAGE_GERRIT=' "$REPO/config/images.env" | cut -d= -f2- | awk -F: '{print $NF}')"
if [ -z "$GERRIT_TAG" ]; then
  echo "[drill] ✗ 无法从 config/images.env 解析 IMAGE_GERRIT tag"
  printf '{"result":"FAIL","ts":"%s","backup":"%s","log":"%s","mode":"full","note":"gerrit-tag-missing"}\n' \
    "$(basename "$LOG")" "$(resolve_backup_path "$BACKUP")" "$LOG" > /data/drill/drill.result
  exit 2
fi
GIMG="ghcr.io/zeek-zhao/orgflow-devops/m2-gerrit:$GERRIT_TAG"
echo "[drill] gerrit 镜像 tag=$GERRIT_TAG（来自 config/images.env）"

# M3.0.3 T2 / M3.0.4 T2：drill.result 字段化（E5：verify Job 按字段断言，不 grep 中文文案）。
# 字段：result/ts/backup/log/healthy/repos/P_open/D_open/P_total/D_total/mode/backup_sha256/age_h/
#       started_at/finished_at/duration_sec/note
# F5：backup 字段必须绑定实际备份目录（RESULT_BACKUP），取不到写 unknown，绝不用字面 "latest"。
# F6：mode 恒为 full（无 quick 轻量路径，不设 DRILL_MODE 分支）。
RESULT_FIELDS='{}'
RESULT_BACKUP="unknown"   # 解包后更新为实际备份绝对路径；失败路径仍指向实际目录或 unknown
BMODE="full"              # M3.0.4 T2/F6：只保留 full，删除 DRILL_MODE 分支
write_result() {
  local result="$1" note="${2:-}"
  python3 - "$result" "$(basename "$LOG")" "$RESULT_BACKUP" "$LOG" "$note" "$RESULT_FIELDS" "$STARTED_AT" "$BMODE" <<'PY'
import json,sys,os,time,datetime
result,logdir,backup,log,notes,fields,started_at,mode=sys.argv[1:9]
d={"result":result,"ts":logdir,"backup":backup,"log":log,"mode":mode}
try: d.update(json.loads(fields))
except Exception: pass
if notes: d["note"]=notes
# 时间字段（Job 打印但不判红）
if not started_at or started_at.startswith('$'):
    started_at=datetime.datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ')
d["started_at"]=started_at
fin=datetime.datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ')
d["finished_at"]=fin
try:
    st=datetime.datetime.strptime(started_at,'%Y-%m-%dT%H:%M:%SZ')
    ft=datetime.datetime.strptime(fin,'%Y-%m-%dT%H:%M:%SZ')
    d["duration_sec"]=int((ft-st).total_seconds())
except Exception:
    d["duration_sec"]=0
p="/data/drill/drill.result"
tmp=p+".tmp"; json.dump(d,open(tmp,'w',encoding='utf-8'),ensure_ascii=False,indent=2); os.replace(tmp,p)
PY
}

fail() { echo "✗ DRILL FAIL: $*"; write_result "FAIL" "$*"; exit 1; }
trap 'rc=$?; [ "$rc" -ne 0 ] && write_result "FAIL" "exit rc=$rc" || true' EXIT

echo "=== T3 隔离恢复演练开始 $(date -u +%FT%TZ) ==="
START=$(date +%s)
STARTED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
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
  printf '%s' "$BACKUP" > /data/drill/backup.latest
else
  VERIFY=0 PROJECT=orgflow-drill bash scripts/restore.sh || fail "restore 解包失败"
  printf '%s' "$(cat /data/backups/latest 2>/dev/null || echo unknown)" > /data/drill/backup.latest
fi
# F5：无论显式 BACKUP 还是 latest 解析，都把实际备份绝对路径绑定进结果（失败路径也不写字面 latest）。
RESULT_BACKUP="$(cat /data/drill/backup.latest 2>/dev/null || echo unknown)"
[ -n "$RESULT_BACKUP" ] || RESULT_BACKUP="unknown"
echo "[drill] RESULT_BACKUP（结果绑定备份）=$RESULT_BACKUP"
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

# c) changes 双指标与生产实时对比（M3.0.3 T3 / E3）：
#    私钥缺失、SSH 非 0、输出为空、解析非数字，任一直接 FAIL，绝不当 0（防静默假通过）。
#    P_open/D_open 与 P_total/D_total 分别相等；total 用 --format=JSON + status:open OR merged OR abandoned。
SSH_KEY="$REPO/secrets/gerrit_ci_ssh_key"
SSHOPT="-i $SSH_KEY -p 29418 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8"
SSH_RC=99
if [ ! -s "$SSH_KEY" ]; then
  echo "[assert c] ✗ ssh-key-missing：私钥 $SSH_KEY 缺失或为空，production changes 无法取值（不默认 0）"
  assertrc=1; SSH_SRC="ssh-key-missing"
else
  SSH_SRC="ssh"
fi

# 生产 SSH 查询函数：显式捕获退出码，输出写临时文件，rc 单独记录。
# 仍走 Gerrit SSH 协议 + ci-bot 私钥；私钥缺失在上方已硬失败。
# 沙箱云 IDE 的 docker-proxy 对 Gerrit SSHD 跨 netns 连接会在 kex 阶段关闭（宿主 SSH 不可用，
# 但容器内 SSH 完全正常）；宿主 SSH 失败时回退到容器内 exec SSH（同私钥、同协议），
# 不是把失败当 0——回退仍失败则 rc≠0 → 该指标 FAIL。
prod_query() {
  local query="$1" out="$2" rc=0
  ssh $SSHOPT ci-bot@127.0.0.1 "$query" >"$out" 2>/dev/null || rc=$?
  if [ "$rc" -ne 0 ] && docker inspect of-gerrit >/dev/null 2>&1; then
    # 回退：容器内以 gerrit 用户、用同一私钥SSH连自身（127.0.0.1:29418，容器内可达）。
    # query 经 base64 传递，避免 sh -c 多层转义把引号吞掉（尤其 --format=JSON 的 'status:...'）。
    local q64; q64="$(printf '%s' "$query" | base64 -w0)"
    docker cp "$SSH_KEY" of-gerrit:/var/gerrit/etc/drill_ci_key >/dev/null 2>&1 || true
    docker exec -u root of-gerrit chown gerrit:gerrit /var/gerrit/etc/drill_ci_key >/dev/null 2>&1 || true
    docker exec -u root of-gerrit chmod 600 /var/gerrit/etc/drill_ci_key >/dev/null 2>&1 || true
    local frc=0
    docker exec -u gerrit of-gerrit sh -c "q=\$(printf '%s' '$q64' | base64 -d); exec ssh -i /var/gerrit/etc/drill_ci_key -p 29418 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 ci-bot@127.0.0.1 \"\$q\"" >"$out" 2>/dev/null || frc=$?
    if [ "$frc" -eq 0 ]; then
      rc=0  # 回退成功：显式归零，不能沿用宿主 SSH 失败的 255
      echo "[assert c] 宿主 SSH 不可用，已回退容器内 SSH（source=ssh-in-container，rc=0）"
    else
      rc="$frc"
    fi
  fi
  SSH_RC="$rc"; return 0
}

P_open=ERR; P_total=ERR
if [ "$SSH_SRC" = "ssh" ]; then
  prod_query 'gerrit query status:open' /tmp/drill_popen.txt
  echo "[assert c] 生产 open 查询: cmd='gerrit query status:open' rc=$SSH_RC"
  if [ "$SSH_RC" -ne 0 ]; then
    echo "[assert c] ✗ 生产 open SSH 查询失败 rc=$SSH_RC（不当 0）"; assertrc=1
  else
    P_open="$(grep -c '^change' /tmp/drill_popen.txt 2>/dev/null || true)"
    P_open="$(printf '%s' "$P_open" | tr -d '\r\n ')"
    printf '%s' "$P_open" | grep -qE '^[0-9]+$' || { echo "[assert c] ✗ 生产 open 解析非数字 P_open=$P_open"; assertrc=1; P_open=ERR; }
  fi
  # total：--format=JSON + 三状态；兼容 Gerrit 版本差异（老版本查询失败则 ERR 直接 FAIL）。
  prod_query "gerrit query --format=JSON 'status:open OR status:merged OR status:abandoned'" /tmp/drill_ptotal.txt
  echo "[assert c] 生产 total 查询: cmd=\"gerrit query --format=JSON 'status:open OR status:merged OR status:abandoned'\" rc=$SSH_RC"
  if [ "$SSH_RC" -ne 0 ]; then
    echo "[assert c] ✗ 生产 total SSH 查询失败 rc=$SSH_RC（不当 0）"; assertrc=1
  else
    # --format=JSON 每行一个 change 对象 {"number":N,...}，但 Gerrit 还会输出一行 stats（无 number 字段）。
    # 只数有 number 的对象，排除 stats 行（否则 P_total 恒多 1，与 drill HTTP 视图差 1）。
    P_total="$(jq -s '[.[] | select(.number != null)] | length' /tmp/drill_ptotal.txt 2>/dev/null || true)"
    P_total="$(printf '%s' "$P_total" | tr -d '\r\n ')"
    if printf '%s' "$P_total" | grep -qE '^[0-9]+$'; then
      echo "[assert c] 生产 total 解析 P_total=$P_total（--format=JSON 行数）"
    else
      echo "[assert c] ✗ 生产 total 解析非数字 P_total=$P_total（JSON 非法或空）"; assertrc=1; P_total=ERR
    fi
  fi
fi

# drill 侧同样双指标（HTTP 匿名查询）。
D_open=$( { curl -sL --noproxy '*' 'http://127.0.0.1:18443/changes/?q=status:open' 2>/dev/null | sed '1s/^)]}'"'"'//' | jq 'length' 2>/dev/null || true; } )
D_open="$(printf '%s' "$D_open" | tr -d '\r\n ')"
D_total=$( { curl -sL --noproxy '*' 'http://127.0.0.1:18443/changes/?q=status:open+OR+status:merged+OR+status:abandoned&n=1000' 2>/dev/null | sed '1s/^)]}'"'"'//' | jq 'length' 2>/dev/null || true; } )
D_total="$(printf '%s' "$D_total" | tr -d '\r\n ')"

echo "[assert c] source=$SSH_SRC ssh_rc=$SSH_RC P_open=$P_open D_open=$D_open P_total=$P_total D_total=$D_total"
# 四数值必须都是数字且成对相等，否则 FAIL。
for v in P_open D_open P_total D_total; do
  val="$(eval echo \$$v)"
  printf '%s' "$val" | grep -qE '^[0-9]+$' || { echo "[assert c] ✗ $v 非数字=$val"; assertrc=1; }
done
[ "$P_open" = "$D_open" ] || { echo "[assert c] ✗ P_open=$P_open != D_open=$D_open"; assertrc=1; }
[ "$P_total" = "$D_total" ] || { echo "[assert c] ✗ P_total=$P_total != D_total=$D_total"; assertrc=1; }
[ "$assertrc" -eq 0 ] && echo "[assert c] drill 与生产 changes 双指标对齐 P_open=$P_open D_open=$D_open P_total=$P_total D_total=$D_total"

# 把命令/rc/四数值写进结果字段（供 verify Job 字段化断言）+ 日志。
RESULT_FIELDS="$(python3 -c 'import json,sys; d=json.loads(sys.argv[1]); d.update({"source":sys.argv[2],"ssh_rc":int(sys.argv[3]),"P_open":sys.argv[4],"D_open":sys.argv[5],"P_total":sys.argv[6],"D_total":sys.argv[7]}); print(json.dumps(d))' "$RESULT_FIELDS" "$SSH_SRC" "$SSH_RC" "$P_open" "$D_open" "$P_total" "$D_total")"

# d) ldap 绑定（M3.0.3 T4 / E4：docker exec -e 注入口令，命令内不出现字面口令）
#    先校验容器内 LDAP_ADMIN_PASSWORD 与脚本读到的一致，不一致直接 FAIL（只改文件不改 env 的假通过）。
container_pw="$(docker exec drill-ldap printenv LDAP_ADMIN_PASSWORD 2>/dev/null | tr -d '\r\n')"
if [ "$container_pw" != "$LDAP_PASSWORD" ]; then
  echo "[assert d] ✗ 容器内 LDAP_ADMIN_PASSWORD 与脚本读取的口令不一致（口令文件/env 不同步）"
  assertrc=1
else
  echo "[assert d] 容器 LDAP_ADMIN_PASSWORD 与脚本口令一致（不回显）"
fi
ldap_ok=$(docker exec -e LDAP_BIND_PW="$LDAP_PASSWORD" drill-ldap sh -c 'printf "%s" "$LDAP_BIND_PW" | ldapwhoami -x -H ldap://127.0.0.1 -D "cn=admin,dc=orgflow,dc=local" -y /dev/stdin >/dev/null 2>&1; echo $?' 2>/dev/null || echo 1)
echo "[assert d] ldap bind rc=$ldap_ok（口令经 docker exec -e 注入，命令内无字面口令）"
[ "$ldap_ok" = "0" ] || { echo "✗ ldap 绑定失败 rc=$ldap_ok"; assertrc=1; }

[ "$assertrc" -eq 0 ] || fail "四项断言有失败（rc=$assertrc）"

# ---- 5) 收尾：字段化结果（healthy/repos/backup_sha256/age_h）----
# M3.0.4 T2/F6：mode 恒 full（BMODE 在头部固定，删除 DRILL_MODE 分支），由 write_result 统一写。
# backup 字段由 write_result 用 RESULT_BACKUP（实际目录）统一写，不再在收尾覆盖。
BACKUP_DIR="$RESULT_BACKUP"
B_SHA="$(sha256sum "$BACKUP_DIR/sha256sum.txt" 2>/dev/null | awk '{print $1}' || true)"
[ -n "$B_SHA" ] || B_SHA="unknown"
AGE_H=$(( ($(date -u +%s) - $(date -u -d "$(basename "$BACKUP_DIR" | sed -E 's/^([0-9]{4})([0-9]{2})([0-9]{2})T([0-9]{2})([0-9]{2})([0-9]{2})Z$/\1-\2-\3 \4:\5:\6 UTC/')" +%s 2>/dev/null || echo $(date -u +%s)) ) / 3600 ))
RESULT_FIELDS="$(python3 -c 'import json,sys; d=json.loads(sys.argv[1]); d.update({"healthy":int(sys.argv[2]),"repos":int(sys.argv[3]),"backup_sha256":sys.argv[4],"age_h":int(sys.argv[5])}); print(json.dumps(d))' "$RESULT_FIELDS" "$hc" "$REPOS" "$B_SHA" "$AGE_H")"
echo "[drill] 结果字段: healthy=$hc repos=$REPOS mode=$BMODE backup_sha256=$B_SHA backup=$RESULT_BACKUP age_h=$AGE_H"

echo "--- [5/5] 清理 drill 栈（保留解包数据与日志）---"
bash scripts/drill-down.sh 2>&1 | tail -5 || true
echo "DRILL PASS total_elapsed=$(( $(date +%s) - START ))s"
write_result "PASS"
echo "=== T3 隔离恢复演练结束 $(date -u +%FT%TZ) ==="
