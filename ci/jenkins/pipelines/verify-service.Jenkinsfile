// 单服务局域网探测流水线（M1）：在 orgflow-agent 上执行 check-lan.sh <SERVICE>。
// LDAP 口令经 Jenkins 凭据 ldap-admin-password 注入 env（不进命令行/console）。
pipeline {
    agent { label 'orgflow-agent' }
    options { timestamps(); timeout(time: 5, unit: 'MINUTES') }
    stages {
        stage('probe') {
            steps {
                withCredentials([string(credentialsId: 'ldap-admin-password', variable: 'LDAP_BIND_PASSWORD')]) {
                    sh '''
                        echo "SERVICE=${SERVICE}  whoami=$(whoami)  uid=$(id -u)"
                        /opt/orgflow/shared/bin/check-lan.sh "${SERVICE}"
                    '''
                }
            }
        }
    }
    post {
        always { cleanWs() }
    }
}
