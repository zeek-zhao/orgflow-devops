// verify-backup（M3.0.1 T2）：备份可信的四项断言。任一失败 → FAILURE（报告红行，杜绝只写 description）。
// 只读消费宿主 /data/backups（挂到 agent /opt/orgflow/backups:ro），无 docker.sock、无 python3；
// 用 jq + shell 实现校验。
// 断言：
//   a) latest 存在且解析出的目录存在，备份年龄 ≤26h（用目录名 UTC 时间戳判定）；
//   b) sha256sum -c sha256sum.txt 全部 OK；
//   c) manifest.json 可解析且 total_volumes=9，每卷 entries>0；
//   d) status.json 的 exit_code=0；
//   e) （M3.0.2 T2）status.json 的 verify.ok=true 且 verify.failures 为空 —— 校验失败必须判红。
// 失败写 /tmp/backup_desc.txt，由 script 块回写 currentBuild.description 供 selfcheck 取 evidence。
pipeline {
    agent { label 'orgflow-agent' }
    options { timestamps(); timeout(time: 8, unit: 'MINUTES'); skipDefaultCheckout(true) }
    stages {
        stage('Verify backup trust') {
            steps {
                sh '''
                    set -uo pipefail
                    B=/opt/orgflow/backups
                    rc=0
                    fail() { echo "✗ $*"; rc=1; }
                    [ -d "$B" ] || { echo "✗ 备份根 $B 未挂载"; echo "BACKUP_FAIL no-mount" > /tmp/backup_desc.txt; exit 1; }

                    # ---- 断言 a: latest 存在 + 目录存在 + 年龄 ≤26h ----
                    if [ ! -f "$B/latest" ]; then
                      fail "latest 指针不存在"
                    else
                      latest_raw="$(cat "$B/latest" 2>/dev/null | tr -d '\\r\\n')"
                      dname="$(basename "$latest_raw")"
                      # latest 存宿主绝对路径，容器内映射为 $B/<basename>
                      dest="$B/$dname"
                      echo "[backup] latest_raw=$latest_raw dest=$dest"
                      [ -d "$dest" ] || fail "latest 指向目录不存在: $dest"
                      if ! printf '%s' "$dname" | grep -qE '^[0-9]{8}T[0-9]{6}Z$'; then
                        fail "latest 目录名非 UTC 格式: $dname"
                      else
                        # 20261128T105035Z -> 2026-11-28 10:50:35 -> epoch（dash 无子串展开，用 cut）
                        ymd="$(printf '%s' "$dname" | cut -c1-8)"
                        hms="$(printf '%s' "$dname" | cut -c10-15)"
                        iso="$(printf '%s' "$ymd" | cut -c1-4)-$(printf '%s' "$ymd" | cut -c5-6)-$(printf '%s' "$ymd" | cut -c7-8) $(printf '%s' "$hms" | cut -c1-2):$(printf '%s' "$hms" | cut -c3-4):$(printf '%s' "$hms" | cut -c5-6)"
                        ets=$(date -u -d "$iso" +%s 2>/dev/null || echo 0)
                        now=$(date -u +%s)
                        [ "$ets" -gt 0 ] || fail "latest 时间戳非法: $dname"
                        age_h=$(( (now - ets) / 3600 ))
                        echo "[backup] backup_age=${age_h}h (max=26h)"
                        [ "$age_h" -le 26 ] || fail "备份年龄 ${age_h}h >26h"
                      fi
                    fi

                    # ---- 断言 b: sha256sum -c 全 OK ----
                    if [ -n "${dest:-}" ] && [ -f "$dest/sha256sum.txt" ]; then
                      ( cd "$dest" && sha256sum -c sha256sum.txt ) || fail "sha256sum -c 有 FAIL"
                    else
                      fail "sha256sum.txt 缺失"
                    fi

                    # ---- 断言 c: manifest 解析 + total_volumes=9 + 每卷 entries>0（jq）----
                    if [ -n "${dest:-}" ] && [ -f "$dest/manifest.json" ]; then
                      jq -e . "$dest/manifest.json" >/dev/null 2>&1 || fail "manifest.json 非法 JSON"
                      tv="$(jq -r '.total_volumes // empty' "$dest/manifest.json" 2>/dev/null)"
                      nv="$(jq -r '.volumes | length' "$dest/manifest.json" 2>/dev/null)"
                      [ "$tv" = "9" ] || fail "total_volumes=$tv != 9"
                      [ "$nv" = "9" ] || fail "volumes length=$nv != 9"
                      bad="$(jq -r '[.volumes[] | select((.entries // 0) <= 0)] | length' "$dest/manifest.json" 2>/dev/null)"
                      [ "$bad" = "0" ] || fail "manifest 有 $bad 卷 entries<=0"
                      sum="$(jq -r '[.volumes[].entries] | add' "$dest/manifest.json" 2>/dev/null)"
                      echo "[backup] manifest OK total_volumes=$tv volumes=$nv entries_sum=$sum"
                    else
                      fail "manifest.json 缺失"
                    fi

                    # ---- 断言 d: status.json exit_code=0（jq）----
                    if [ -f "$B/status.json" ]; then
                      code="$(jq -r '.exit_code // "missing"' "$B/status.json" 2>/dev/null || echo missing)"
                      echo "[backup] status.exit_code=$code"
                      [ "$code" = "0" ] || fail "status.exit_code=$code != 0"
                    else
                      fail "status.json 缺失"
                    fi

                    # ---- 断言 e: status.verify.ok=true 且 failures 为空（M3.0.2 T2）----
                    if [ -f "$B/status.json" ]; then
                      vok="$(jq -r 'if .verify|type=="object" then (.verify.ok|tostring) else "missing" end' "$B/status.json" 2>/dev/null || echo missing)"
                      vfails="$(jq -r '.verify.failures // [] | join(",")' "$B/status.json" 2>/dev/null || echo unreadable)"
                      echo "[backup] status.verify.ok=$vok failures=[$vfails]"
                      [ "$vok" = "true" ] || fail "status.verify.ok=$vok != true（校验失败被吞）"
                      [ -z "$vfails" ] || fail "status.verify.failures=[$vfails] 非空"
                    else
                      fail "status.json 缺失（无法校验 verify）"
                    fi

                    # ---- 断言 f: status.backup 与 latest 同源 + finished_at 与 latest 时间差 ≤2h（M3.0.4 T1/F2）----
                    # 防"旧 status 套新备份"：status.backup 必须与 latest 指针内容完全一致（同一份备份），
                    # 且 status.finished_at 与 latest 目录名时间的差不超过 2 小时。
                    if [ -f "$B/status.json" ] && [ -f "$B/latest" ]; then
                      sb="$(jq -r '.backup // "missing"' "$B/status.json" 2>/dev/null || echo missing)"
                      lr="$(cat "$B/latest" 2>/dev/null | tr -d '\\r\\n')"
                      echo "[backup] status.backup=$sb latest=$lr"
                      [ "$sb" = "$lr" ] || fail "status.backup=$sb != latest=$lr（状态与最新备份不同源）"
                      # 时间差：finished_at(ISO) 与 latest 目录名(UTC) 相差 ≤7200s
                      fin="$(jq -r '.finished_at // "missing"' "$B/status.json" 2>/dev/null || echo missing)"
                      ldname="$(basename "$lr")"
                      lymd="$(printf '%s' "$ldname" | cut -c1-8)"
                      lhms="$(printf '%s' "$ldname" | cut -c10-15)"
                      liso="$(printf '%s' "$lymd" | cut -c1-4)-$(printf '%s' "$lymd" | cut -c5-6)-$(printf '%s' "$lymd" | cut -c7-8) $(printf '%s' "$lhms" | cut -c1-2):$(printf '%s' "$lhms" | cut -c3-4):$(printf '%s' "$lhms" | cut -c5-6)"
                      lets=$(date -u -d "$liso" +%s 2>/dev/null || echo 0)
                      fets=$(date -u -d "$fin" +%s 2>/dev/null || echo 0)
                      if [ "$lets" -le 0 ] || [ "$fets" -le 0 ]; then
                        fail "时间解析失败 finished_at=$fin latest_ts=$liso"
                      else
                        diff=$(( fets - lets )); [ "$diff" -lt 0 ] && diff=$(( -diff ))
                        echo "[backup] status.finished_at 与 latest 时间差=${diff}s (max=7200s)"
                        [ "$diff" -le 7200 ] || fail "finished_at 与 latest 时间差=${diff}s >7200s（疑似旧状态套新备份）"
                      fi
                    else
                      fail "status.json 或 latest 缺失（无法校验同源）"
                    fi

                    if [ "$rc" -eq 0 ]; then
                      echo "✓ 备份六项断言全过（age=${age_h:-?}h sha256=OK manifest=9 status=0 verify=ok 同源=OK）"
                      printf 'BACKUP_OK age=%sh volumes=9 exit=0 verify=ok same-source=ok' "${age_h:-?}" > /tmp/backup_desc.txt
                    else
                      printf 'BACKUP_FAIL 见 console（断言 a/b/c/d/e/f 有失败）' > /tmp/backup_desc.txt
                    fi
                    exit "$rc"
                '''
                script {
                    if (fileExists('/tmp/backup_desc.txt')) {
                        currentBuild.description = readFile('/tmp/backup_desc.txt').trim()
                    }
                }
            }
        }
    }
    post { always { cleanWs() } }
}
