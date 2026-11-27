// verify-quota-refresh（m2.5.3 P0-2 功能级自检 Job）：校验「刷新机制存活」，堵住第二个假绿窗口。
//
// 背景（m2.5.3 P0-2）：guard-quota 只校验证据新鲜度，不校验"谁在产证据"。若机制已死，
// 证据会在 5~10 分钟内仍显示新鲜，自检照样 PASS。本 Job 补三项判据，任一失败→FAILURE（报告红行）：
//   1) 机制声明/进程存活：artifacts/quota/alive.json 与 daemon.pid 的 pid 命令行匹配 quota-guard-loop.sh
//      （ps -p PID -o args= 比对，不只 kill -0，避免 PID 复用误判）；
//   2) 日志新鲜：cron.log（或 supervisor.log）最后一行时间距今 ≤8 分钟；
//   3) 证据新鲜：latest-of-builder.json 的 age ≤10 分钟。
//
// 只读消费：证据经 artifacts/quota 只读挂到 /opt/orgflow/quota；agent 无 docker.sock、无法跨
// PID namespace 看宿主进程，故存活信号由宿主侧 quota-guard-loop.sh 写 alive.json 自证。
// description 输出 mechanism=<...>，selfcheck 报告据此在顶部 meta 展示当前生效机制。
pipeline {
    agent { label 'orgflow-agent' }
    options { timestamps(); timeout(time: 3, unit: 'MINUTES'); skipDefaultCheckout(true) }
    stages {
        stage('Verify refresh mechanism alive') {
            steps {
                sh '''
                    set -uo pipefail
                    QDIR=/opt/orgflow/quota
                    ALIVE="$QDIR/alive.json"
                    EVID="$QDIR/latest-of-builder.json"
                    MECH="none"
                    [ -f "$QDIR/mechanism.txt" ] && MECH="$(cat "$QDIR/mechanism.txt" 2>/dev/null | tr -d '\\r\\n')"

                    rc=0
                    echo "[refresh] mechanism(declared)=$MECH"

                    # ---- 判据1：机制存活（alive.json 的 pid 命令行匹配 quota-guard-loop.sh）----
                    if [ ! -f "$ALIVE" ]; then
                      echo "✗ 缺 $ALIVE（刷新循环未在宿主运行）"; rc=1
                    else
                      jq -e . "$ALIVE" >/dev/null 2>&1 || { echo "✗ alive.json 非法 JSON"; rc=1; }
                      apid="$(jq -r '.pid // empty' "$ALIVE")"
                      aargs="$(jq -r '.args // empty' "$ALIVE")"
                      aalive="$(jq -r '.alive // empty' "$ALIVE")"
                      atsm="$(jq -r '.ts // empty' "$ALIVE")"
                      echo "[refresh] alive pid=$apid args=$aargs alive=$aalive ts=$atsm"
                      # 命令行匹配（宿主侧已用 ps 自证，这里再核一次字段，防篡改）
                      if ! printf '%s' "$aargs" | grep -qF 'quota-guard-loop.sh'; then
                        echo "✗ alive.args 不含 quota-guard-loop.sh（PID 复用或伪造）"; rc=1
                      fi
                      [ "$aalive" = "true" ] || { echo "✗ alive=false（宿主 ps 未匹配到刷新进程）"; rc=1; }
                      # alive.ts 距今 ≤8min（循环每 5min 刷新一次）
                      if [ -n "$atsm" ]; then
                        ets=$(date -u -d "$atsm" +%s 2>/dev/null || echo 0)
                        now=$(date -u +%s)
                        [ "$ets" -gt 0 ] || { echo "✗ alive.ts 非法"; rc=1; }
                        aage=$(( (now - ets) / 60 ))
                        echo "[refresh] alive age=${aage}min"
                        [ "$aage" -le 8 ] || { echo "✗ 刷新心跳过期 ${aage}min >8min（机制可能已死）"; rc=1; }
                      fi
                    fi

                    # 判据1b：机制声明与实际 alive.mechanism 一致
                    if [ -f "$ALIVE" ] && [ "$MECH" != "none" ]; then
                      amech="$(jq -r '.mechanism // empty' "$ALIVE")"
                      [ "$amech" = "$MECH" ] || { echo "✗ mechanism 声明($MECH)≠alive($amech)"; rc=1; }
                    fi

                    # ---- 判据2：日志新鲜（cron.log / supervisor.log 最后写入 ≤8min）----
                    logf=""
                    for f in "$QDIR/cron.log" "$QDIR/supervisor.log"; do
                      [ -f "$f" ] && { logf="$f"; break; }
                    done
                    if [ -z "$logf" ]; then
                      echo "✗ 无 cron.log/supervisor.log"; rc=1
                    else
                      # 优先用 alive.json 的 log_last_ts（容器内文件 mtime 与宿主可能不同步）
                      lts="$(jq -r '.log_last_ts // empty' "$ALIVE" 2>/dev/null)"
                      if [ -z "$lts" ]; then
                        lts="$(date -u -r "$logf" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo '')"
                      fi
                      if [ -z "$lts" ]; then echo "✗ 日志时间戳不可读"; rc=1
                      else
                        lets=$(date -u -d "$lts" +%s 2>/dev/null || echo 0)
                        now=$(date -u +%s)
                        [ "$lets" -gt 0 ] || { echo "✗ 日志时间戳非法: $lts"; rc=1; }
                        lage=$(( (now - lets) / 60 ))
                        echo "[refresh] log=$logf last=$lts age=${lage}min"
                        [ "$lage" -le 8 ] || { echo "✗ 日志过期 ${lage}min >8min"; rc=1; }
                      fi
                    fi

                    # ---- 判据3：证据 age ≤10min ----
                    if [ ! -f "$EVID" ]; then
                      echo "✗ 缺 $EVID"; rc=1
                    else
                      etsm="$(jq -r '.ts // empty' "$EVID")"
                      verdict="$(jq -r '.verdict // empty' "$EVID")"
                      ets="$(date -u -d "$etsm" +%s 2>/dev/null || echo 0)"
                      [ "$ets" -gt 0 ] || { echo "✗ evidence.ts 非法: $etsm"; rc=1; }
                      now=$(date -u +%s)
                      eage=$(( (now - ets) / 60 ))
                      echo "[refresh] evidence verdict=$verdict age=${eage}min"
                      [ "$verdict" = "PASS" ] || { echo "✗ verdict=$verdict"; rc=1; }
                      [ "$eage" -le 10 ] || { echo "✗ 证据过期 ${eage}min >10min"; rc=1; }
                    fi

                    if [ "$rc" -eq 0 ]; then
                      printf 'REFRESH_ALIVE mechanism=%s alive_age<=8min log<=8min evidence<=10min' "$MECH" > /tmp/refresh_desc.txt
                      echo "✓ 刷新机制存活三项判据全过（mechanism=$MECH）"
                    else
                      printf 'REFRESH_DEAD mechanism=%s 存在失败判据（见 console）' "$MECH" > /tmp/refresh_desc.txt
                    fi
                    exit "$rc"
                '''
                script {
                    if (fileExists('/tmp/refresh_desc.txt')) {
                        currentBuild.description = readFile('/tmp/refresh_desc.txt').trim()
                    }
                }
            }
        }
    }
    post { always { cleanWs() } }
}
