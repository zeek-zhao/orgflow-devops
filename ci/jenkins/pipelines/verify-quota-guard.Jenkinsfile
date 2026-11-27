// verify-quota-guard（M2.5 P0 功能级自检 Job）：只读消费宿主 quota-guard 证据。
// 跑在 orgflow-agent，无 docker.sock；证据经 artifacts/quota 只读挂到 /opt/orgflow/quota。
// 断言 verdict==PASS / container==of-builder / 三项配额为 0；不满足则本 Job FAIL（报告该行红）。
// m2.5.1 P1-1：固定读 latest-of-builder.json（按容器名隔离，不受单服务重建覆盖）。
// m2.5.1 P2-2：输出 age 字段；age>10min 时本 Job 仍 SUCCESS（不判 FAIL，与构建门禁口径解耦），
//   但在 currentBuild.description 写 "QUOTA_WARN age=Nmin ..."；selfcheck 报告据此把该行标 WARN
//   并在顶部注明"真实构建将被 Quota gate 拦"，避免误判"自检全绿=能构建"。
pipeline {
    agent { label 'orgflow-agent' }
    options { timestamps(); timeout(time: 3, unit: 'MINUTES'); skipDefaultCheckout(true) }
    stages {
        stage('Verify quota evidence') {
            steps {
                sh '''
                    set -e
                    # 门禁固定读 latest-of-builder.json；latest.json 仅为人类查看副本，不参与门禁。
                    Q=/opt/orgflow/quota/latest-of-builder.json
                    [ -f "$Q" ] || { echo "✗ 缺少配额证据 $Q（先在宿主跑 up.sh / quota-guard.sh）"; exit 1; }
                    jq -e . "$Q" >/dev/null 2>&1 || { echo "✗ 配额证据 JSON 非法"; exit 1; }

                    verdict="$(jq -r '.verdict // empty' "$Q")"
                    container="$(jq -r '.container // empty' "$Q")"
                    ts="$(jq -r '.ts // empty' "$Q")"
                    nano="$(jq -r '.inspect.nano_cpus // empty' "$Q")"
                    mem="$(jq -r '.inspect.memory // empty' "$Q")"
                    quota="$(jq -r '.inspect.cpu_quota // empty' "$Q")"

                    # m2.5.1 P2-2：计算证据 age（分钟）
                    age_min="unknown"; age_sec=-1
                    if [ -n "$ts" ]; then
                      ets=$(date -u -d "$ts" +%s 2>/dev/null || echo 0)
                      now=$(date -u +%s)
                      if [ "$ets" -gt 0 ]; then
                        age_sec=$(( now - ets )); age_min=$(( age_sec / 60 ))
                      fi
                    fi

                    echo "[quota] nproc=$(jq -r '.host.nproc' "$Q")"
                    echo "[quota] MemTotal=$(jq -r '.host.mem_total_kb' "$Q") kB"
                    echo "[quota] docker info NCPU=$(jq -r '.docker.ncpu' "$Q") MemTotal=$(jq -r '.docker.mem_total_bytes' "$Q")"
                    echo "[quota] inspect NanoCpus=$nano Memory=$mem CpuQuota=$quota"
                    echo "[quota] verdict=$verdict container=$container ts=$ts age=${age_min}min"

                    rc=0
                    [ "$verdict" = "PASS" ] || { echo "✗ verdict 非 PASS: $verdict"; rc=1; }
                    [ "$container" = "of-builder" ] || { echo "✗ container 非 of-builder: $container"; rc=1; }
                    [ "$nano" = "0" ] || { echo "✗ NanoCpus 非 0: $nano"; rc=1; }
                    [ "$mem" = "0" ] || { echo "✗ Memory 非 0: $mem"; rc=1; }
                    [ "$quota" = "0" ] || { echo "✗ CpuQuota 非 0: $quota"; rc=1; }

                    # 新鲜度告警：不作为本 Job 失败条件，通过 description 传给 selfcheck 报告口径。
                    stale_warn=""
                    if [ "$rc" -eq 0 ]; then
                      if [ "$age_sec" -lt 0 ]; then
                        stale_warn="QUOTA_WARN age=unknown ts无效；真实构建将被 Quota gate 拦（请先刷新证据）"
                      elif [ "$age_min" -gt 10 ]; then
                        stale_warn="QUOTA_WARN age=${age_min}min >10min；真实构建将被 Quota gate 拦（请先刷新证据）"
                      fi
                    fi
                    if [ "$rc" -eq 0 ]; then
                      if [ -n "$stale_warn" ]; then
                        echo "⚠ $stale_warn"
                        echo "QUOTA_OK_WARN"
                        printf '%s' "$stale_warn" > /tmp/quota_desc.txt
                      else
                        echo "✓ 构建资源配额证据 PASS（宿主全资源、容器无限制、age=${age_min}min 新鲜）"
                        echo "QUOTA_OK_FRESH"
                        printf 'QUOTA_FRESH age=%smin verdict=PASS' "$age_min" > /tmp/quota_desc.txt
                      fi
                    fi
                    exit "$rc"
                '''
                script {
                    // 把新鲜度结论写进 build description，供 selfcheck 报告取 evidence 判 WARN。
                    if (fileExists('/tmp/quota_desc.txt')) {
                        currentBuild.description = readFile('/tmp/quota_desc.txt').trim()
                    }
                }
            }
        }
    }
    post { always { cleanWs() } }
}
