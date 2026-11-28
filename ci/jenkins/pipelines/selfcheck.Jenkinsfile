// selfcheck 编排流水线（M2.4 Phase3）：顶层 agent none（编排不占 orgflow-agent），
// 用 node('built-in') 在 controller 上读写文件（controller 挂了 /opt/orgflow/ci:ro 与 /reports/selfcheck:rw；
// jenkins.yaml 给 built-in 放 1 个 executor，专供本 Job，不碰凭据/无 docker.sock）。
// 子 Job 经 build step 在 orgflow-agent 执行；build 不依赖 node context。
// SKIPPED 语义：从未构建过的子 Job 记 SKIPPED，不算 FAIL，计入“未覆盖 N 项”。
// 敏感信息约束：报告只含 id/title/what/result/duration/consoleUrl/证据，不含口令/私钥/IP。
// 沙箱约束：不用 groovy.json.*（未进 script-security 白名单）；stage 间用脚本级变量传数据，
// JSON/HTML 全部用字符串拼接生成。
def checks = []
def selected = []
def results = []
def overall = 'n/a'

pipeline {
    agent none
    options {
        timestamps()
        timeout(time: 20, unit: 'MINUTES')
        buildDiscarder(logRotator(daysToKeepStr: '14', numToKeepStr: '20'))
    }
    stages {
        stage('Load checks') {
            steps {
                node('built-in') {
                    script {
                        def tsv = sh(script: 'cat /opt/orgflow/ci/selfcheck/checks.tsv', returnStdout: true).trim()
                        checks = []
                        tsv.readLines().each { ln ->
                            if (!ln.trim() || ln.startsWith('id\t')) return
                            def f = ln.split('\t', -1)
                            if (f.length < 7) return
                            checks << [id:f[0], kind:f[1], target:f[2], title:f[3], what:f[4], expect:f[5]]
                        }
                        def include = (params.INCLUDE ?: '').split(',').collect{it.trim()}.findAll{it}
                        def exclude = (params.EXCLUDE ?: '').split(',').collect{it.trim()}.findAll{it}
                        selected = checks.findAll { c ->
                            (include.isEmpty() || c.id in include) && !(c.id in exclude)
                        }
                        echo "自检 ${selected.size()} 项 / 共 ${checks.size()} 项；INCLUDE=${params.INCLUDE} EXCLUDE=${params.EXCLUDE}"
                    }
                }
            }
        }
        stage('Run checks') {
            steps {
                script {
                    results = []
                    selected.each { c ->
                        def row = [id:c.id, title:c.title, what:c.what, target:c.target, result:'SKIPPED', duration:'', evidence:'', consoleUrl:'']
                        try {
                            def run = build job: c.target, wait: true, propagate: false
                            def res = run.getResult()?.toString() ?: 'UNKNOWN'
                            // Jenkins 原始结果是 FAILURE；报告口径统一为 FAIL（与 NEGATIVE/门禁一致）
                            if (res == 'FAILURE') res = 'FAIL'
                            row.result = (run.getNumber() > 0) ? res : 'SKIPPED'
                            row.duration = run.getDurationString() ?: ''
                            row.consoleUrl = "${env.JENKINS_URL}job/${c.target}/${run.getNumber()}/console"
                            try { row.evidence = (run.getDescription() ?: '') } catch (Exception e) { row.evidence = '' }
                        } catch (Exception e) {
                            row.result = 'SKIPPED'
                            row.evidence = 'build 异常: ' + e.getClass().getSimpleName()
                        }
                        if (params.NEGATIVE && results.isEmpty()) {
                            row.result = 'FAIL'; row.evidence = 'NEGATIVE=true 演示失败态（未改真实子 Job）'
                        }
                        // m2.5.1 P2-2：verify-quota-guard 在 evidence(description) 写 QUOTA_WARN 时，
                        // 该行由 SUCCESS 降级为 WARN（不算 FAIL，overall 不受影响），报告顶部注明
                        // "真实构建将被 Quota gate 拦"，避免误判"自检全绿=能构建"。
                        if (row.result == 'SUCCESS' && (row.evidence ?: '').contains('QUOTA_WARN')) {
                            row.result = 'WARN'
                        }
                        results << row
                        echo "  [${row.result}] ${c.id} ${c.title} ${row.duration}"
                    }
                    def nFail = results.count{it.result in ['FAIL','UNKNOWN','ABORTED']}
                    def nSkip = results.count{it.result == 'SKIPPED'}
                    overall = (nFail > 0) ? 'FAIL' : (nSkip > 0 ? 'PARTIAL' : 'PASS')
                    echo "总判=${overall} FAIL=${nFail} SKIPPED=${nSkip}"
                }
            }
        }
        stage('Publish report') {
            steps {
                node('built-in') {
                    script {
                        def nFail = results.count{it.result in ['FAIL','UNKNOWN','ABORTED']}
                        def nSkip = results.count{it.result == 'SKIPPED'}
                        def nWarn = results.count{it.result == 'WARN'}
                        // M2.5 P1-3 / M3.0.1 T4：commit 来源改为 Pipeline 内 git rev-parse HEAD（注入 GIT_COMMIT），
                        // 不再从挂载的 config 推断。repo 根只读挂到 /opt/orgflow/repo（见 jenkins compose）；
                        // 只读挂载属主 root、jenkins uid1000 → dubious ownership，用 -c safe.directory 内联豁免。
                        // 取全 SHA（不再 --short），取不到写 unknown + warning。
                        def commit = sh(script: "git -c safe.directory='*' -C /opt/orgflow/repo rev-parse HEAD 2>/dev/null || echo unknown", returnStdout: true).trim()
                        if (commit == 'unknown') { echo "⚠ 报告 commit=unknown：/opt/orgflow/repo 不可读或非 git 仓库" }
                        // T4：deployedHead = 工作区实际头（同一 git rev-parse，独立取一次便于将来替换来源）；
                        // consistent = 二者是否一致（YES/NO）。报告顶部显示两行。
                        def deployedHead = sh(script: "git -c safe.directory='*' -C /opt/orgflow/repo rev-parse HEAD 2>/dev/null || echo unknown", returnStdout: true).trim()
                        def consistent = (commit != 'unknown' && commit == deployedHead) ? 'YES' : 'NO'
                        echo "报告同源: report_commit=${commit} deployed_head=${deployedHead} consistent=${consistent}"
                        // 2) Jenkins 版本：jenkins.version → war MANIFEST Implementation-Version → unknown。
                        def jver = sh(script: '''
                            v="$(cat /var/jenkins_home/jenkins.version 2>/dev/null | tr -d '\\r\\n' || true)"
                            [ -n "$v" ] && { echo "$v"; exit 0; }
                            war="$(find / -maxdepth 4 -name jenkins.war 2>/dev/null | head -1)"
                            if [ -n "$war" ]; then
                                v="$(unzip -p "$war" META-INF/MANIFEST.MF 2>/dev/null | tr -d '\\r' | sed -n 's/^Implementation-Version: //p' | head -1)"
                                [ -n "$v" ] && { echo "$v"; exit 0; }
                            fi
                            echo unknown
                        ''', returnStdout: true).trim()
                        if (jver == 'unknown') { echo "⚠ 报告 jenkinsVersion=unknown：版本文件与 war MANIFEST 均不可读" }
                        def now = sh(script: "date '+%Y-%m-%d %H:%M:%S %z'", returnStdout: true).trim()
                        // 3) 镜像：输出 键=值（仅镜像名与 tag，无口令），报告表格单独一列"镜像 tag"。
                        def images = sh(script: "grep -E '^IMAGE_[A-Z_]+=' /opt/orgflow/config/images.env 2>/dev/null | tr '\\n' ' '", returnStdout: true).trim()
                        def imageKeys = sh(script: "grep -E '^IMAGE_[A-Z_]+=' /opt/orgflow/config/images.env 2>/dev/null | cut -d= -f1 | tr '\\n' ' '", returnStdout: true).trim()

                        // M2.5 P2-2：heavy 未纳入本轮时，报告顶部显式注明。
                        def excl = (params.EXCLUDE ?: '').split(',').collect{it.trim()}
                        def heavyNote = (excl.contains('feat-review-flow'))
                            ? 'heavy 评审流（feat-review-flow）未纳入本轮：默认跳过，改由单独定时任务执行。'
                            : ''
                        // m2.5.1 P2-2：配额证据过期只标 WARN（不判 FAIL），但报告顶部显式提示
                        // 真实构建将被 Quota gate 拦，避免误读"自检全绿=能构建"。
                        def quotaWarnNote = (nWarn > 0)
                            ? '⚠ 有 ' + nWarn + ' 项配额证据过期/异常（WARN，不计 FAIL），但真实构建将被 Quota gate 拦；请先在宿主刷新证据（make quota-guard / 等待 timer 自动刷新）。'
                            : ''
                        // m2.5.5 P2-1：mechanism 来源独立化——不再从 guard-quota-alive 行 description 提取
                        // （行红了就没有 mechanism= 前缀，导致报告 mechanism=unknown 被 FAIL 行带崩）。
                        // 优先级：/opt/orgflow/quota/mechanism.txt → alive.json.mechanism → unknown。
                        // 与存活校验结果解耦：即便 guard-quota-alive 红，机制声明仍可读。
                        def mechanism = sh(script: '''
                            QDIR=/opt/orgflow/quota
                            mech="unknown"
                            if [ -f "$QDIR/mechanism.txt" ]; then
                              m="$(cat "$QDIR/mechanism.txt" 2>/dev/null | tr -d '\\r\\n')"
                              [ -n "$m" ] && mech="$m"
                            fi
                            if [ "$mech" = "unknown" ] && [ -f "$QDIR/alive.json" ]; then
                              m="$(jq -r '.mechanism // empty' "$QDIR/alive.json" 2>/dev/null)"
                              [ -n "$m" ] && mech="$m"
                            fi
                            echo "$mech"
                        ''', returnStdout: true).trim()
                        if (!mechanism) mechanism = 'unknown'
                        echo "报告 mechanism 来源独立化：mechanism=${mechanism}"
                        def json = buildJson(env.BUILD_NUMBER, now, overall, commit, deployedHead, consistent, jver, imageKeys, images, heavyNote, quotaWarnNote, mechanism, results, nFail, nSkip, nWarn)
                        def html = renderHtml(env.BUILD_NUMBER, now, overall, commit, deployedHead, consistent, jver, imageKeys, images, heavyNote, quotaWarnNote, mechanism, results, nFail, nSkip, nWarn)
                        def reportDir = '/reports/selfcheck'
                        def base = "${reportDir}/selfcheck-${env.BUILD_NUMBER}"
                        writeFile file: "${base}.json", text: json
                        writeFile file: "${base}.html", text: html
                        writeFile file: "${reportDir}/latest.html", text: html
                        writeFile file: "${reportDir}/latest.json", text: json
                        echo "报告已生成: ${base}.html / latest.html"
                        currentBuild.description = "SELFCHECK ${overall} (FAIL=${nFail} SKIP=${nSkip})"
                        // m2.5.5 P0-2：把总判回写到构建结果，消除"报告红、构建绿"的假绿。
                        // FAIL（有 FAIL/UNKNOWN/ABORTED）→ FAILURE；PARTIAL/PASS → SUCCESS。
                        // 与 description 的 SELFCHECK ${overall} 口径一致；通知/看板/API 据此可见红。
                        // 注意：currentBuild.result 只能在 pipeline 内设置，且只可写 SUCCESS/FAILURE/UNSTABLE/ABORTED/NOT_BUILT。
                        currentBuild.result = (overall == 'FAIL') ? 'FAILURE' : 'SUCCESS'
                        echo "构建结果已回写: currentBuild.result=${currentBuild.result} (overall=${overall})"
                    }
                }
            }
        }
    }
    post { always { echo "自检结束：${currentBuild.description ?: 'n/a'}" } }
}

// 手工 JSON 序列化（沙箱无 groovy.json.JsonOutput）：字符串转义 + 拼接。
def buildJson(build, now, overall, commit, deployedHead, consistent, jver, imageKeys, images, heavyNote, quotaWarnNote, mechanism, results, nFail, nSkip, nWarn) {
    def esc = { s -> (s ?: '').toString()
        .replace('\\', '\\\\').replace('"', '\\"')
        .replace('\n', '\\n').replace('\r', '\\r').replace('\t', '\\t') }
    def rows = results.collect { r ->
        '{' + '"id":"' + esc(r.id) + '","title":"' + esc(r.title) + '","what":"' + esc(r.what) +
        '","target":"' + esc(r.target) + '","result":"' + esc(r.result) + '","duration":"' + esc(r.duration) +
        '","evidence":"' + esc(r.evidence) + '","consoleUrl":"' + esc(r.consoleUrl) + '"}'
    }.join(',')
    // m2.5.4 P2-1：overall 与 result 并存且同值——机器消费方按 result 读，HTML 仍用 overall。
    // m3.0.1 T4：deployedHead/consistent 同源字段——报告顶部两行，机器可直接校验同源性。
    return '{' + '"build":"' + esc(build) + '","time":"' + esc(now) + '","overall":"' + esc(overall) +
        '","result":"' + esc(overall) +
        '","commit":"' + esc(commit) + '","deployedHead":"' + esc(deployedHead) + '","consistent":"' + esc(consistent) +
        '","jenkinsVersion":"' + esc(jver) + '","imageKeys":"' + esc(imageKeys) +
        '","images":"' + esc(images) + '","heavyNote":"' + esc(heavyNote) + '","quotaWarnNote":"' + esc(quotaWarnNote) +
        '","mechanism":"' + esc(mechanism) + '"' +
        ',"fail":' + nFail + ',"skipped":' + nSkip + ',"warn":' + nWarn + ',"total":' + results.size() +
        ',"results":[' + rows + ']}'
}

// 自包含 HTML：内联 CSS、无外链、无 JS；表格 + 状态色块 + 总判 + 环境快照 + 未覆盖提示。
def renderHtml(build, now, overall, commit, deployedHead, consistent, jver, imageKeys, images, heavyNote, quotaWarnNote, mechanism, results, nFail, nSkip, nWarn) {
    def esc = { s -> (s ?: '').toString().replace('&','&amp;').replace('<','&lt;').replace('>','&gt;').replace('"','&quot;') }
    def color = overall=='PASS' ? '#2e7d32' : (overall=='FAIL' ? '#c62828' : '#ef6c00')
    def sb = ''
    sb = sb + '<!doctype html><html lang="zh-CN"><head><meta charset="utf-8">'
    sb = sb + '<meta name="viewport" content="width=device-width,initial-scale=1">'
    sb = sb + '<title>OrgFlow 自检报告 #' + build + '</title>'
    sb = sb + '<style>body{font-family:system-ui,sans-serif;max-width:1000px;margin:2rem auto;padding:0 1rem;color:#1b2430}'
    sb = sb + 'h1{font-size:1.5rem}.verdict{display:inline-block;padding:.4rem 1rem;border-radius:6px;color:#fff;font-weight:700;background:' + color + '}'
    sb = sb + 'table{border-collapse:collapse;width:100%;margin-top:1rem}th,td{border:1px solid #d8dee9;padding:.45rem .6rem;text-align:left;font-size:.9rem}'
    sb = sb + 'th{background:#f2f5f9}.ok{color:#2e7d32;font-weight:700}.fail{color:#c62828;font-weight:700}.skip{color:#ef6c00;font-weight:700}'
    sb = sb + '.meta{color:#556;font-size:.85rem}.ev{font-family:monospace;font-size:.8rem;color:#444}.note{margin-top:1rem;color:#556}</style></head><body>'
    sb = sb + '<h1>OrgFlow 自检报告 <span class="meta">#' + build + '</span></h1>'
    sb = sb + '<p>生成时间：' + esc(now) + '　总判：<span class="verdict">' + overall + '</span></p>'
    // m3.0.1 T4：报告顶部两行——工作区实际头 / 报告 commit，并给一致性结论。
    def consColor = (consistent=='YES') ? '#2e7d32' : '#c62828'
    sb = sb + '<p class="meta">deployed_head（工作区实际头）：<span class="ev">' + esc(deployedHead) + '</span></p>'
    sb = sb + '<p class="meta">report_commit（报告采集头）：<span class="ev">' + esc(commit) +
        '</span>　同源：<span style="color:' + consColor + ';font-weight:700">' + esc(consistent) + '</span></p>'
    if (heavyNote) sb = sb + '<p class="note" style="color:#ef6c00">⚠ ' + esc(heavyNote) + '</p>'
    // m2.5.1 P2-2：配额证据过期告警（WARN 不判 FAIL），顶部显式提示构建将被拦。
    if (quotaWarnNote) sb = sb + '<p class="note" style="color:#ef6c00">⚠ ' + esc(quotaWarnNote) + '</p>'
    sb = sb + '<p class="meta">commit=' + esc(commit) + '　Jenkins=' + esc(jver) + '　mechanism=' + esc(mechanism)
    sb = sb + '　检查=' + results.size() + '　FAIL=' + nFail + '　WARN=' + nWarn + '　SKIPPED=' + nSkip + '</p>'
    // M2.5 P1-3：镜像段输出 键=值（仅名与 tag），单独列一栏"镜像 tag"，不再只列键名。
    if (images) {
        sb = sb + '<h2 style="font-size:1.05rem;margin-top:1.2rem">镜像 tag（环境快照）</h2>'
        sb = sb + '<table><thead><tr><th>变量</th><th>镜像 tag</th></tr></thead><tbody>'
        images.split(' ').findAll{it}.each { kv ->
            def p = kv.split('=', 2)
            sb = sb + '<tr><td class="ev">' + esc(p[0]) + '</td><td class="ev">' + esc(p.length > 1 ? p[1] : '') + '</td></tr>'
        }
        sb = sb + '</tbody></table>'
    }
    sb = sb + '<table><thead><tr><th>检查项</th><th>测什么</th><th>结果</th><th>耗时</th><th>证据</th><th>Console</th></tr></thead><tbody>'
    results.each { r ->
        def cls = (r.result=='SUCCESS') ? 'ok' : (r.result=='FAIL' ? 'fail' : 'skip')  // WARN/SKIPPED 同用橙色
        sb = sb + '<tr><td>' + esc(r.id) + ' ' + esc(r.title) + '</td>'
        sb = sb + '<td>' + esc(r.what) + '</td>'
        sb = sb + '<td class="' + cls + '">' + esc(r.result) + '</td>'
        sb = sb + '<td>' + esc(r.duration) + '</td>'
        sb = sb + '<td class="ev">' + esc(r.evidence) + '</td>'
        sb = sb + '<td>' + (r.consoleUrl ? '<a href="' + esc(r.consoleUrl) + '">log</a>' : '—') + '</td></tr>'
    }
    sb = sb + '</tbody></table>'
    if (nSkip > 0) sb = sb + '<p class="note">注意：有 ' + nSkip + ' 项从未构建（SKIPPED），不计入 FAIL，但未覆盖，请人工确认。</p>'
    sb = sb + '<p class="note">报告为自包含静态页，不含任何口令/私钥/内网 IP。历史见同目录 selfcheck-&lt;build&gt;.html。</p>'
    sb = sb + '</body></html>'
    return sb
}
