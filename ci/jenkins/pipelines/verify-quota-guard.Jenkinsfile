// verify-quota-guard（M2.5 P0 功能级自检 Job）：只读消费宿主 quota-guard 证据。
// 跑在 orgflow-agent，无 docker.sock；证据经 artifacts/quota 只读挂到 /opt/orgflow/quota。
// 断言 verdict==PASS / container==of-builder / 三项配额为 0；不满足则本 Job FAIL（报告该行红）。
// 新鲜度在 build-from-gerrit 的 Quota gate 严格判（≤10min）；此处仅打印 ts 供人工核对，
// 避免自检运行时机与 up.sh 刷新间隔导致误报。
pipeline {
    agent { label 'orgflow-agent' }
    options { timestamps(); timeout(time: 3, unit: 'MINUTES'); skipDefaultCheckout(true) }
    stages {
        stage('Verify quota evidence') {
            steps {
                sh '''
                    set -e
                    Q=/opt/orgflow/quota/latest.json
                    [ -f "$Q" ] || { echo "✗ 缺少配额证据 $Q（先在宿主跑 up.sh / quota-guard.sh）"; exit 1; }
                    jq -e . "$Q" >/dev/null 2>&1 || { echo "✗ 配额证据 JSON 非法"; exit 1; }

                    verdict="$(jq -r '.verdict // empty' "$Q")"
                    container="$(jq -r '.container // empty' "$Q")"
                    ts="$(jq -r '.ts // empty' "$Q")"
                    nano="$(jq -r '.inspect.nano_cpus // empty' "$Q")"
                    mem="$(jq -r '.inspect.memory // empty' "$Q")"
                    quota="$(jq -r '.inspect.cpu_quota // empty' "$Q")"

                    echo "[quota] nproc=$(jq -r '.host.nproc' "$Q")"
                    echo "[quota] MemTotal=$(jq -r '.host.mem_total_kb' "$Q") kB"
                    echo "[quota] docker info NCPU=$(jq -r '.docker.ncpu' "$Q") MemTotal=$(jq -r '.docker.mem_total_bytes' "$Q")"
                    echo "[quota] inspect NanoCpus=$nano Memory=$mem CpuQuota=$quota"
                    echo "[quota] verdict=$verdict container=$container ts=$ts"

                    rc=0
                    [ "$verdict" = "PASS" ] || { echo "✗ verdict 非 PASS: $verdict"; rc=1; }
                    [ "$container" = "of-builder" ] || { echo "✗ container 非 of-builder: $container"; rc=1; }
                    [ "$nano" = "0" ] || { echo "✗ NanoCpus 非 0: $nano"; rc=1; }
                    [ "$mem" = "0" ] || { echo "✗ Memory 非 0: $mem"; rc=1; }
                    [ "$quota" = "0" ] || { echo "✗ CpuQuota 非 0: $quota"; rc=1; }
                    if [ "$rc" -eq 0 ]; then echo "✓ 构建资源配额证据 PASS（宿主全资源、容器无限制）"; fi
                    exit "$rc"
                '''
            }
        }
    }
    post { always { cleanWs() } }
}
