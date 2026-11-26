// 评审流功能级探测（M2.4 Phase3，heavy）：建探针 change → 触发构建 → Verified +1 → abandon。
// 凭据（不入库/不进日志）：
//   gerrit-http  : zeek.zhao 的 HTTP Basic（push refs/for/main + REST 查询/abandon）
//   gerrit-ci-ssh: ci-bot 私钥（SSH 查询 --all-approvals，只读）
// host key 固定校验（known_hosts 落卷），不用 StrictHostKeyChecking=no。
//
// 关键实现约束（M2.4-P3 实测）：
//   1. Gerrit canonicalWebUrl 指向公网 https://<host>:8443，容器内经代理-http:8080 访问时若不带
//      canonical Host + X-Forwarded-Proto:https 会 301 到公网 TLS 边缘（容器内不可达 → GnuTLS/000）。
//      故所有 HTTP 交互都经 http.extraHeader / curl -H 注入这两个头，走内网 :8080。
//   2. agent 的 sh 用 /bin/sh（dash），禁用 [[ ]]；统一 POSIX 语法。
//   3. 探针一定在 post.always abandon，保持 open 列表干净。
pipeline {
    agent { label 'orgflow-agent' }
    options { timestamps(); timeout(time: 20, unit: 'MINUTES'); skipDefaultCheckout(true) }
    environment {
        KH          = '/opt/orgflow/config/known_hosts'
        GERRIT_HOST = 'gerrit'
        GERRIT_PORT = '8080'
        GHDR_HOST   = 'orgflow-sandbox.tail0b7621.ts.net'  // canonicalWebUrl host，绕开 301
    }
    stages {
        stage('Probe review flow') {
            steps {
                withCredentials([
                  usernamePassword(credentialsId: 'gerrit-http', usernameVariable: 'GH_USER', passwordVariable: 'GH_PASS'),
                  sshUserPrivateKey(credentialsId: 'gerrit-ci-ssh', keyFileVariable: 'GERRIT_KEY')
                ]) {
                    sh '''
                        set -e
                        H1="Host: ${GHDR_HOST}"
                        H2="X-Forwarded-Proto: https"
                        AUTH="${GH_USER}:${GH_PASS}"
                        BASE="http://${GERRIT_HOST}:${GERRIT_PORT}"

                        rm -rf probe && mkdir probe && cd probe
                        git init -q
                        git -c http.extraHeader="$H1" -c http.extraHeader="$H2" \
                            fetch -q --depth=1 "http://${AUTH}@${GERRIT_HOST}:${GERRIT_PORT}/orgflow-devops" refs/heads/main
                        git checkout -q FETCH_HEAD
                        curl -s -o .git/hooks/commit-msg -H "$H1" -H "$H2" "$BASE/tools/hooks/commit-msg"
                        chmod +x .git/hooks/commit-msg
                        git config user.name "Zeek Zhao"; git config user.email "zeek.zhao@foxmail.com"

                        echo "selfcheck probe $(date +%s)" >> README.md
                        git add README.md
                        git commit -q -m "test(selfcheck): gerrit review flow probe"
                        PUSH_OUT="$(git -c http.extraHeader="$H1" -c http.extraHeader="$H2" \
                            push "http://${AUTH}@${GERRIT_HOST}:${GERRIT_PORT}/orgflow-devops" HEAD:refs/for/main 2>&1 || true)"
                        echo "$PUSH_OUT" | tail -6
                        CHANGE="$(echo "$PUSH_OUT" | grep -oE '/\\+/[0-9]+' | head -1 | tr -dc '0-9' || true)"
                        if [ -z "$CHANGE" ]; then
                          CHANGE="$(curl -s -u "$AUTH" -H "$H1" -H "$H2" \
                            "$BASE/a/changes/?q=status:open&n=1&o=CURRENT_REVISION" \
                            | tr ',' '\\n' | grep -oE '"_number":[0-9]+' | head -1 | cut -d: -f2 || true)"
                        fi
                        echo "PROBE_CHANGE=$CHANGE"
                        [ -n "$CHANGE" ] || { echo "无法解析探针 change 号"; exit 1; }
                        echo "$CHANGE" > ../probe_change.txt
                    '''
                }
            }
        }
        stage('Wait Verified +1') {
            steps {
                withCredentials([sshUserPrivateKey(credentialsId: 'gerrit-ci-ssh', keyFileVariable: 'GERRIT_KEY')]) {
                    script {
                        def change = sh(script: 'cat probe_change.txt', returnStdout: true).trim()
                        def ok = false
                        for (int i = 0; i < 12; i++) {
                            // Verified 查询封装在共享库脚本，避免 Groovy 三引号对 $ 的转义坑；
                            // GERRIT_KEY/KH 由本 stage withCredentials + env 注入（跨 stage 不继承凭据）。
                            def labels = sh(
                                script: "/opt/orgflow/shared/bin/gerrit-check-verified.sh ${change} 2>/dev/null || true",
                                returnStdout: true).trim()
                            echo "  第 ${i+1} 次查询 Verified: [${labels}]"
                            if (labels.contains('1')) { ok = true; break }
                            sleep 15
                        }
                        if (!ok) { error "探针 change ${change} 未观察到 Verified +1" }
                        echo "评审流闭环：change ${change} Verified +1"
                    }
                }
            }
        }
    }
    post {
        always {
            script {
                try {
                    def change = sh(script: 'cat probe_change.txt 2>/dev/null || true', returnStdout: true).trim()
                    if (change) {
                        withCredentials([usernamePassword(credentialsId: 'gerrit-http', usernameVariable: 'GH_USER', passwordVariable: 'GH_PASS')]) {
                            // abandon 封装在共享库脚本（单引号调用，避免 Groovy 对 JSON 引号的转义坑）。
                            sh "/opt/orgflow/shared/bin/gerrit-abandon.sh ${change} || true"
                        }
                    }
                } catch (Exception e) { echo "abandon 探针失败（忽略）: ${e}" }
            }
            cleanWs()
        }
    }
}
