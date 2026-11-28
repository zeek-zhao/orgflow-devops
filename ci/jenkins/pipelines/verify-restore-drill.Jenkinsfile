// verify-restore-drill（M3.0.1 T3）：隔离恢复演练结果校验 Job（cron 每周日 04:30）。
// 沙箱 agent 无 docker.sock，不能自行起栈（与 M2.5 quota 同机制）：宿主侧由 drill-up.sh 真实起
// 独立栈并把结果写 /data/drill/drill.result + /data/drill-logs/<ts>/drill-up.log；本 Job 只读消费
// 结果做断言（离线校验，理由同 T4「Jenkins 实例隔离起栈内存不足改离线配置校验」）。
// 断言：
//   1) drill.result == DRILL PASS；
//   2) 最近一次日志含四项断言通过行（cgit 200 / gerrit 3.9.x / changes 0 / ldap rc=0）；
//   3) 结果新鲜（日志 mtime ≤8 天）；
//   4) 起栈资源守卫 verdict=PASS（四项资源铁律）。
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

                    # 1) drill.result
                    if [ ! -f "$D/drill.result" ]; then fail "缺 $D/drill.result"; else
                      result="$(cat "$D/drill.result" | tr -d '\\r\\n')"
                      echo "[drill] result=$result"
                      [ "$result" = "DRILL PASS" ] || fail "drill.result=$result != DRILL PASS"
                    fi

                    # 找最近一次日志
                    logf="$(find "$L" -name drill-up.log -type f -printf '%T@ %p\\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)"
                    [ -n "$logf" ] || { fail "无 drill-up.log"; logf=""; }
                    if [ -n "$logf" ]; then
                      echo "[drill] latest log=$logf"
                      # 2) 四项断言通过行
                      grep -q 'cgit / HTTP=200' "$logf" || fail "日志缺 cgit 200"
                      grep -qE 'gerrit version=.*3\\.9\\.' "$logf" || fail "日志缺 gerrit 3.9.x"
                      grep -q 'open changes=0' "$logf" || fail "日志缺 changes=0"
                      grep -q 'ldap bind rc=0' "$logf" || fail "日志缺 ldap rc=0"
                      grep -q 'DRILL PASS' "$logf" || fail "日志缺 DRILL PASS 收尾"
                      # 3) 新鲜度 ≤8 天
                      age_s=$(( $(date +%s) - $(stat -c %Y "$logf" 2>/dev/null || echo 0) ))
                      age_d=$(( age_s / 86400 ))
                      echo "[drill] log age=${age_d}d (max=8d)"
                      [ "$age_d" -le 8 ] || fail "日志过期 ${age_d}d >8d"
                      # 4) 资源守卫
                      grep -q 'verdict=PASS' "$logf" || fail "日志缺 quota verdict=PASS"
                    fi

                    if [ "$rc" -eq 0 ]; then
                      echo "✓ 隔离恢复演练结果校验通过（四项断言全过 + 新鲜 + 资源守卫 PASS）"
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
