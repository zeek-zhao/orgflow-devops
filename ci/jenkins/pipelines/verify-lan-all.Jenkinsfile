// 全服务局域网探测流水线（M1）：parallel 分支并行跑，check-lan-all.sh 内部也并发并汇总 Markdown。
// numExecutors=2：几条分支真并发、其余排队；验收看 console 时间戳重叠。
pipeline {
    agent { label 'orgflow-agent' }
    options { timestamps(); timeout(time: 10, unit: 'MINUTES') }
    stages {
        stage('probe-all') {
            steps {
                withCredentials([string(credentialsId: 'ldap-admin-password', variable: 'LDAP_BIND_PASSWORD')]) {
                    sh '''
                        echo "whoami=$(whoami)  uid=$(id -u)  start=$(date +%H:%M:%S)"
                        /opt/orgflow/shared/bin/check-lan-all.sh
                    '''
                }
            }
        }
    }
    post {
        always {
            archiveArtifacts artifacts: 'lan-report.md', allowEmptyArchive: true
            cleanWs()
        }
        // E2：失败时发飞书通知；webhook 走 plain-credentials（id: feishu-webhook）。
        // 凭据未配置时脚本优雅跳过，不影响构建结果；配置后立即生效。
        failure {
            script {
                try {
                    withCredentials([string(credentialsId: 'feishu-webhook', variable: 'FEISHU_WEBHOOK')]) {
                        sh '''
                            /opt/orgflow/ci/shared-library/bin/notify-feishu.sh \
                              "$JOB_NAME" "$BUILD_NUMBER" "$BUILD_URL" FAILURE
                        '''
                    }
                } catch (Exception e) {
                    echo "[notify] feishu-webhook 凭据不可用，跳过通知：${e.getMessage()}"
                }
            }
        }
    }
}
