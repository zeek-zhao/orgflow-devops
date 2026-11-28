// verify-restore-drill（M3.0.3 T1/T2）：隔离恢复演练结果校验 Job（纯手动，无 cron）。
// 沙箱 agent 无 docker.sock：宿主侧由 make drill 前台跑 drill-up.sh 产出 JSON 结果
// /data/drill/drill.result（字段化）+ /data/drill-logs/<ts>/drill-up.log；本 Job 只读消费做断言。
// M3.0.3 T2（E1）：删除"结果 ≤26h"判红，改为打印 age_h 信息字段（演练是人工动作，
//   放进每次自检会造成"没演练就红、演练了也只绿一天"的假信号）；但 result 缺失/FAIL 仍 FAILURE。
// M3.0.3 T2 字段化断言（不再 grep 中文文案，E5）：
//   result=PASS / healthy=3 / repos=3 / P_open=D_open / P_total=D_total /
//   backup_sha256 与 manifest 一致 / mode ∈ {quick,full}。
pipeline {
    agent { label 'orgflow-agent' }
    options { timestamps(); timeout(time: 3, unit: 'MINUTES'); skipDefaultCheckout(true) }
    stages {
        stage('Verify restore drill result') {
            steps {
                sh '''
                    set -uo pipefail
                    D=/opt/orgflow/drill
                    L=/opt/orgflow/drill-logs
                    rc=0
                    fail() { echo "✗ $*"; rc=1; }

                    # 0) 必须有结果文件，否则先 make drill（T2 反证要求提示此文案）
                    if [ ! -f "$D/drill.result" ]; then
                      echo "✗ 缺结果，请先 make drill（隔离恢复演练是手动动作）"
                      fail "缺 $D/drill.result，请先 make drill"
                      exit 1
                    fi
                    jq -e . "$D/drill.result" >/dev/null 2>&1 || { fail "drill.result 非合法 JSON"; exit 1; }

                    # ---- 字段化断言（E5：不依赖中文文案）----
                    result="$(jq -r '.result // "missing"' "$D/drill.result" 2>/dev/null)"
                    rts="$(jq -r '.ts // "missing"' "$D/drill.result" 2>/dev/null)"
                    echo "[drill] result=$result ts=$rts"
                    [ "$result" = "PASS" ] || fail "result=$result != PASS"

                    healthy="$(jq -r '.healthy // "missing"' "$D/drill.result" 2>/dev/null)"
                    repos="$(jq -r '.repos // "missing"' "$D/drill.result" 2>/dev/null)"
                    popen="$(jq -r '.P_open // "missing"' "$D/drill.result" 2>/dev/null)"
                    dopen="$(jq -r '.D_open // "missing"' "$D/drill.result" 2>/dev/null)"
                    ptotal="$(jq -r '.P_total // "missing"' "$D/drill.result" 2>/dev/null)"
                    dtotal="$(jq -r '.D_total // "missing"' "$D/drill.result" 2>/dev/null)"
                    mode="$(jq -r '.mode // "missing"' "$D/drill.result" 2>/dev/null)"
                    bsha="$(jq -r '.backup_sha256 // "missing"' "$D/drill.result" 2>/dev/null)"
                    echo "[drill] healthy=$healthy repos=$repos P_open=$popen D_open=$dopen P_total=$ptotal D_total=$dtotal mode=$mode"
                    echo "[drill] backup_sha256=$bsha"

                    [ "$healthy" = "3" ] || fail "healthy=$healthy != 3"
                    [ "$repos" = "3" ] || fail "repos=$repos != 3"
                    [ "$popen" = "$dopen" ] || fail "P_open=$popen != D_open=$dopen"
                    [ "$ptotal" = "$dtotal" ] || fail "P_total=$ptotal != D_total=$dtotal"
                    case "$mode" in quick|full) ;; *) fail "mode=$mode 非 quick/full" ;; esac

                    printf '%s' "$rts" | grep -qE '^[0-9]{8}T[0-9]{6}Z$' || fail "ts 非法: $rts"
                    # backup_sha256 交叉校验：drill-up 与 Job 同口径，取 sha256sum.txt 文件自身的 sha256。
                    # agent 挂 /data/backups → /opt/orgflow/backups:ro，把宿主路径映射到挂载点。
                    backup_dir="$(jq -r '.backup // empty' "$D/drill.result" 2>/dev/null)"
                    mnt="/opt/orgflow/backups/$(basename "$backup_dir" 2>/dev/null)"
                    if [ -n "$backup_dir" ] && [ -f "$mnt/sha256sum.txt" ]; then
                      msha="$(sha256sum "$mnt/sha256sum.txt" 2>/dev/null | awk '{print $1}')"
                      echo "[drill] backup_sha256 交叉校验: result=$bsha manifest=$msha"
                      [ "$bsha" = "$msha" ] || fail "backup_sha256=$bsha != 备份 sha256sum.txt 的 sha256=$msha"
                    else
                      fail "backup_sha256 无法交叉校验：备份目录不可读（$mnt）"
                    fi

                    # ---- 年龄只作信息字段，不判红（T2）----
                    ymd="$(printf '%s' "$rts" | cut -c1-8)"; hms="$(printf '%s' "$rts" | cut -c10-15)"
                    iso="$(printf '%s' "$ymd" | cut -c1-4)-$(printf '%s' "$ymd" | cut -c5-6)-$(printf '%s' "$ymd" | cut -c7-8) $(printf '%s' "$hms" | cut -c1-2):$(printf '%s' "$hms" | cut -c3-4):$(printf '%s' "$hms" | cut -c5-6)"
                    ets=$(date -u -d "$iso" +%s 2>/dev/null || echo 0)
                    now=$(date -u +%s); age_h=$(( (now - ets) / 3600 ))
                    echo "[drill] age=${age_h}h（信息字段，不判红）"

                    # 日志同源：ts 对应日志目录存在（字段化结果要求日志可追溯）
                    logf="$L/$rts/drill-up.log"
                    [ -f "$logf" ] && echo "[drill] 日志同源 OK: $logf" || fail "缺日志文件 $logf"

                    if [ "$rc" -eq 0 ]; then
                      echo "✓ 演练结果校验通过（字段化：result/healthy=3/repos=3/P_open=D_open/P_total=D_total/mode/sha256；age=${age_h}h 仅信息）"
                      printf 'DRILL_VERIFY_OK result=PASS age=%sh' "$age_h" > /tmp/drill_desc.txt
                    else
                      printf 'DRILL_VERIFY_FAIL 见 console' > /tmp/drill_desc.txt
                    fi
                    exit "$rc"
                '''
                script {
                    if (fileExists('/tmp/drill_desc.txt')) {
                        currentBuild.description = readFile('/tmp/drill_desc.txt').trim()
                    }
                }
            }
        }
    }
    post { always { cleanWs() } }
}
