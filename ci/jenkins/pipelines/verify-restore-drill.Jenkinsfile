// verify-restore-drill（M3.0.1 T3 / M3.0.2 T4 增强）：隔离恢复演练结果校验 Job（cron 每周日 04:30）。
// 沙箱 agent 无 docker.sock，不能自行起栈（与 M2.5 quota 同机制）：宿主侧由 drill-daemon.sh 每本地周日
// 04:00 调 drill-up.sh 真实起栈，把 JSON 结果写 /data/drill/drill.result + /data/drill-logs/<ts>/drill-up.log；
// 本 Job 只读消费结果做断言（离线校验）。
// 断言（M3.0.2 T4）：
//   1) drill.result 是合法 JSON，result=PASS；
//   2) JSON.ts（日志目录名 YYYYMMDDTHHMMSSZ）对应的日志目录存在，且其 mtime 与 ts 相差 ≤10min（同源）；
//   3) 新鲜度：result.ts ≤26h（不是旧日志冒充）；
//   4) 该日志含四项断言通过行 + quota verdict=PASS。
// 任一失败 → FAILURE。
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

                    # 1) drill.result 合法 JSON + result=PASS
                    if [ ! -f "$D/drill.result" ]; then
                      fail "缺 $D/drill.result"
                    else
                      jq -e . "$D/drill.result" >/dev/null 2>&1 || fail "drill.result 非合法 JSON"
                      result="$(jq -r '.result // "missing"' "$D/drill.result" 2>/dev/null || echo missing)"
                      rts="$(jq -r '.ts // "missing"' "$D/drill.result" 2>/dev/null || echo missing)"
                      echo "[drill] result=$result ts=$rts"
                      [ "$result" = "PASS" ] || fail "drill.result.result=$result != PASS"
                      printf '%s' "$rts" | grep -qE '^[0-9]{8}T[0-9]{6}Z$' || fail "drill.result.ts 非法: $rts"
                    fi

                    # 2) result.ts 对应日志目录存在且与日志 mtime 同源（≤10min）
                    logdir="$L/$rts"
                    logf="$logdir/drill-up.log"
                    if [ ! -d "$logdir" ] || [ ! -f "$logf" ]; then
                      fail "result.ts 对应日志不存在: $logf"
                    else
                      echo "[drill] result/log 同源目录=$logdir"
                      # ts -> epoch；日志 mtime -> epoch；差 ≤600s
                      ymd="$(printf '%s' "$rts" | cut -c1-8)"
                      hms="$(printf '%s' "$rts" | cut -c10-15)"
                      iso="$(printf '%s' "$ymd" | cut -c1-4)-$(printf '%s' "$ymd" | cut -c5-6)-$(printf '%s' "$ymd" | cut -c7-8) $(printf '%s' "$hms" | cut -c1-2):$(printf '%s' "$hms" | cut -c3-4):$(printf '%s' "$hms" | cut -c5-6)"
                      ets=$(date -u -d "$iso" +%s 2>/dev/null || echo 0)
                      mts=$(stat -c %Y "$logf" 2>/dev/null || echo 0)
                      diff=$(( mts > ets ? mts - ets : ets - mts ))
                      echo "[drill] result ts epoch=$ets log mtime=$mts diff=${diff}s (max=600s)"
                      [ "$ets" -gt 0 ] && [ "$mts" -gt 0 ] || fail "ts/mtime 解析失败"
                      [ "$diff" -le 600 ] || fail "result 与日志不同源 diff=${diff}s >600s"
                      # 3) 新鲜度 ≤26h（用 result.ts 算）
                      now=$(date -u +%s)
                      age_h=$(( (now - ets) / 3600 ))
                      echo "[drill] result age=${age_h}h (max=26h)"
                      [ "$age_h" -le 26 ] || fail "结果过期 ${age_h}h >26h"
                      # 4) 四项断言 + 资源守卫
                      grep -q 'cgit / HTTP=200' "$logf" || fail "日志缺 cgit 200"
                      grep -qE 'gerrit version=.*3\\.9\\.' "$logf" || fail "日志缺 gerrit 3.9.x"
                      # M3.0.2 T5：changes 与生产实时对齐 P==D（drill-up.sh 新文案：changes 对齐 P=N D=N）。
                      # 注意：Groovy 三引号 sh 内不能写反斜杠正则（会被当转义破坏编译），改用 grep -oE + cut。
                      changes_line="$(grep -E 'changes 对齐 P=[0-9]+ D=[0-9]+' "$logf" | tail -1 || true)"
                      if [ -z "$changes_line" ]; then
                        fail "日志缺 changes 对齐断言行"
                      else
                        p="$(printf '%s' "$changes_line" | grep -oE 'P=[0-9]+' | cut -d= -f2)"
                        d="$(printf '%s' "$changes_line" | grep -oE 'D=[0-9]+' | cut -d= -f2)"
                        echo "[drill] changes P=$p D=$d"
                        [ -n "$p" ] && [ "$p" = "$d" ] || fail "changes P=$p != D=$d"
                      fi
                      grep -q 'ldap bind rc=0' "$logf" || fail "日志缺 ldap rc=0"
                      # M3.0.2 T5：healthy=3 必须断言（三容器全 healthy）。
                      grep -q 'healthy 数=3' "$logf" || fail "日志缺 healthy=3 断言"
                      grep -q 'DRILL PASS' "$logf" || fail "日志缺 DRILL PASS 收尾"
                      grep -q 'verdict=PASS' "$logf" || fail "日志缺 quota verdict=PASS"
                    fi

                    if [ "$rc" -eq 0 ]; then
                      echo "✓ 演练结果校验通过（JSON PASS + 同源≤10min + 新鲜≤26h + 四断言 + 资源守卫）"
                      printf 'DRILL_VERIFY_OK result=PASS' > /tmp/drill_desc.txt
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
