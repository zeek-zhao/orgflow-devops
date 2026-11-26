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
                        // 环境快照（不含口令/私钥/IP）
                        def commit = sh(script: "git -C /opt/orgflow rev-parse --short HEAD 2>/dev/null || echo n/a", returnStdout: true).trim()
                        def jver = sh(script: "cat /var/jenkins_home/.jenkins-version 2>/dev/null || echo Jenkins", returnStdout: true).trim()
                        def now = sh(script: "date '+%Y-%m-%d %H:%M:%S %z'", returnStdout: true).trim()
                        def imageKeys = sh(script: "grep -E '^IMAGE_[A-Z_]+=' /opt/orgflow/config/images.env 2>/dev/null | sed 's/=.*//' | tr '\\n' ' '", returnStdout: true).trim()

                        def json = buildJson(env.BUILD_NUMBER, now, overall, commit, jver, imageKeys, results, nFail, nSkip)
                        def html = renderHtml(env.BUILD_NUMBER, now, overall, commit, jver, imageKeys, results, nFail, nSkip)
                        def reportDir = '/reports/selfcheck'
                        def base = "${reportDir}/selfcheck-${env.BUILD_NUMBER}"
                        writeFile file: "${base}.json", text: json
                        writeFile file: "${base}.html", text: html
                        writeFile file: "${reportDir}/latest.html", text: html
                        writeFile file: "${reportDir}/latest.json", text: json
                        echo "报告已生成: ${base}.html / latest.html"
                        currentBuild.description = "SELFCHECK ${overall} (FAIL=${nFail} SKIP=${nSkip})"
                    }
                }
            }
        }
    }
    post { always { echo "自检结束：${currentBuild.description ?: 'n/a'}" } }
}

// 手工 JSON 序列化（沙箱无 groovy.json.JsonOutput）：字符串转义 + 拼接。
def buildJson(build, now, overall, commit, jver, imageKeys, results, nFail, nSkip) {
    def esc = { s -> (s ?: '').toString()
        .replace('\\', '\\\\').replace('"', '\\"')
        .replace('\n', '\\n').replace('\r', '\\r').replace('\t', '\\t') }
    def rows = results.collect { r ->
        '{' + '"id":"' + esc(r.id) + '","title":"' + esc(r.title) + '","what":"' + esc(r.what) +
        '","target":"' + esc(r.target) + '","result":"' + esc(r.result) + '","duration":"' + esc(r.duration) +
        '","evidence":"' + esc(r.evidence) + '","consoleUrl":"' + esc(r.consoleUrl) + '"}'
    }.join(',')
    return '{' + '"build":"' + esc(build) + '","time":"' + esc(now) + '","overall":"' + esc(overall) +
        '","commit":"' + esc(commit) + '","jenkinsVersion":"' + esc(jver) + '","imageKeys":"' + esc(imageKeys) +
        '","fail":' + nFail + ',"skipped":' + nSkip + ',"total":' + results.size() +
        ',"results":[' + rows + ']}'
}

// 自包含 HTML：内联 CSS、无外链、无 JS；表格 + 状态色块 + 总判 + 环境快照 + 未覆盖提示。
def renderHtml(build, now, overall, commit, jver, imageKeys, results, nFail, nSkip) {
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
    sb = sb + '<p class="meta">commit=' + esc(commit) + '　Jenkins=' + esc(jver)
    sb = sb + '　检查=' + results.size() + '　FAIL=' + nFail + '　SKIPPED=' + nSkip + '</p>'
    sb = sb + '<p class="meta">镜像 tag 键：' + esc(imageKeys) + '</p>'
    sb = sb + '<table><thead><tr><th>检查项</th><th>测什么</th><th>结果</th><th>耗时</th><th>证据</th><th>Console</th></tr></thead><tbody>'
    results.each { r ->
        def cls = r.result=='SUCCESS' ? 'ok' : (r.result=='FAIL' ? 'fail' : 'skip')
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
