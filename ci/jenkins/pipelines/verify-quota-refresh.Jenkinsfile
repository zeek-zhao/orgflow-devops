// verify-quota-refresh（m2.5.3 P0-2 功能级自检 Job）：校验「刷新机制存活」，堵住第二个假绿窗口。
//
// 背景（m2.5.3 P0-2）：guard-quota 只校验证据新鲜度，不校验"谁在产证据"。若机制已死，
// 证据会在 5~10 分钟内仍显示新鲜，自检照样 PASS。本 Job 补三项判据，任一失败→FAILURE（报告红行）：
//   1) 机制声明/进程存活：artifacts/quota/alive.json 与 daemon.pid 的 pid 命令行匹配 quota-guard-loop.sh
//      （ps -p PID -o args= 比对，不只 kill -0，避免 PID 复用误判）；
//   2) 日志新鲜：cron.log（或 supervisor.log）最后一行时间距今 ≤8 分钟；
//   3) 证据新鲜：latest-of-builder.json 的 age ≤10 分钟；
//   4) m2.5.4 P0-2 单实例：alive.instances == 1 且 alive.pidfile_pid == alive.pid，
//      否则 FAILURE 并打印实际值 + ps -eo pid,args（双写会让两份证据互相覆盖，必须判红）。
// m2.5.5 P1-1：判据按 mechanism 分支——常驻/瞬时机制不同，不能一刀切要求 pidfile：
//   - supervisor/runit/nohup（常驻 loop）：校验 instances==1 && pidfile_pid==pid && alive 心跳≤8min；
//   - cron/systemd-timer（--once 瞬时，本就不写 pidfile）：不校验 pidfile，改最近一次心跳≤10min；
//   - none/unknown：直接 FAILURE + 诊断提示。
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

                    # m2.5.5 P1-1：按机制分支，先归类（禁止一刀切要求 pidfile）。
                    case "$MECH" in
                      supervisor|runit|nohup) MECH_CLASS=resident; HBEAT_MAX=8 ;;
                      cron|systemd-timer)     MECH_CLASS=transient; HBEAT_MAX=10 ;;
                      *)
                        echo "✗ mechanism='$MECH' 非已知（应为 supervisor/runit/nohup/cron/systemd-timer）"; rc=1
                        MECH_CLASS=unknown; HBEAT_MAX=10 ;;
                    esac
                    echo "[refresh] mechanism_class=$MECH_CLASS hbeat_max=${HBEAT_MAX}min"

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
                      # 常驻机制要求 alive=true；瞬时(--once)模式下 alive 是一次性 ps 自证，同样应为 true。
                      [ "$aalive" = "true" ] || { echo "✗ alive=false（宿主 ps 未匹配到刷新进程）"; rc=1; }
                      # alive.ts 距今阈值按机制：常驻≤8min、瞬时≤10min（cron 每 5min，宽一档避免跨周期误判）。
                      if [ -n "$atsm" ]; then
                        ets=$(date -u -d "$atsm" +%s 2>/dev/null || echo 0)
                        now=$(date -u +%s)
                        [ "$ets" -gt 0 ] || { echo "✗ alive.ts 非法"; rc=1; }
                        aage=$(( (now - ets) / 60 ))
                        echo "[refresh] alive age=${aage}min (max=${HBEAT_MAX}min)"
                        [ "$aage" -le "$HBEAT_MAX" ] || { echo "✗ 刷新心跳过期 ${aage}min >${HBEAT_MAX}min（机制可能已死）"; rc=1; }
                      fi
                    fi

                    # 判据1b：机制声明与实际 alive.mechanism 一致
                    if [ -f "$ALIVE" ] && [ "$MECH" != "none" ]; then
                      amech="$(jq -r '.mechanism // empty' "$ALIVE")"
                      [ "$amech" = "$MECH" ] || { echo "✗ mechanism 声明($MECH)≠alive($amech)"; rc=1; }
                    fi

                    # ---- 判据1c（m2.5.4 P0-2 / m2.5.5 P1-1）：按机制分支校验 ----
                    if [ -f "$ALIVE" ]; then
                      inst="$(jq -r '.instances // empty' "$ALIVE")"
                      pfpid="$(jq -r '.pidfile_pid // empty' "$ALIVE")"
                      echo "[refresh] instances=${inst:-缺失} pidfile_pid=${pfpid:-缺失} pid=$apid"
                      case "$MECH_CLASS" in
                        resident)
                          # 常驻 loop：必须单实例且 pidfile 归当前 PID（心跳每轮续约）。
                          if [ "$inst" != "1" ]; then
                            echo "✗ instances=${inst:-缺失} ≠ 1（检测到双实例/无实例，证据会双写）"
                            echo "  ps -eo pid,args | grep '[q]uota-guard-loop.sh':"
                            ps -eo pid,args 2>/dev/null | grep '[q]uota-guard-loop.sh' || echo "  (容器内看不到宿主进程，以宿主 alive.instances 为准)"
                            rc=1
                          fi
                          if [ "$pfpid" != "$apid" ]; then
                            echo "✗ pidfile_pid=${pfpid:-缺失} ≠ pid=$apid（常驻机制下 pidfile 应每轮续约指向自身）"
                            rc=1
                          fi
                          ;;
                        transient)
                          # 瞬时(--once)：本就不写 pidfile，跳过 pidfile/instances 判据；
                          # 只确认 alive.ts 在 10min 内（最近一次 --once 心跳），判据1 已按 HBEAT_MAX=10 校验。
                          echo "[refresh] transient 机制：跳过 pidfile/instances 判据（--once 不写 pidfile）"
                          ;;
                        unknown)
                          echo "✗ mechanism_class=unknown，无法判定存活语义（见上方诊断）"; rc=1 ;;
                      esac
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
                      # m2.5.5 P1-1：描述口径按机制——常驻才写 instances=1，瞬时写 hbeat<=10min。
                      if [ "$MECH_CLASS" = "resident" ]; then
                        printf 'REFRESH_ALIVE mechanism=%s instances=1 alive_age<=8min log<=8min evidence<=10min' "$MECH" > /tmp/refresh_desc.txt
                      else
                        printf 'REFRESH_ALIVE mechanism=%s hbeat<=10min log<=8min evidence<=10min' "$MECH" > /tmp/refresh_desc.txt
                      fi
                      echo "✓ 刷新机制存活判据全过（mechanism=$MECH class=$MECH_CLASS）"
                    else
                      # 保留 M2.5.4 口径：失败时 description 带 instances=N，供双实例反证直接可读。
                      printf 'REFRESH_DEAD mechanism=%s class=%s instances=%s 存在失败判据（见 console）' "$MECH" "$MECH_CLASS" "${inst:-?}" > /tmp/refresh_desc.txt
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
