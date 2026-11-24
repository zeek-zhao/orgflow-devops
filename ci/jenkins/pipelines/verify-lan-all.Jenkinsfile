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
    }
}
