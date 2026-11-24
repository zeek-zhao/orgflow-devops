// 验证 agent 节点本身（M1）：真实 SSH 会话用户必须是普通用户 jenkins(uid1000)，工具链齐全。
// 注意：这里跑在 agent 的 SSH 会话里（不是 docker exec），附加组按 initgroups() 重置，
// 所以 docker exec -u jenkins 的"假阳性"在这里不成立，uid=1000 是真实结果。
pipeline {
    agent { label 'orgflow-agent' }
    options { timestamps(); timeout(time: 5, unit: 'MINUTES') }
    stages {
        stage('identity') {
            steps {
                sh '''
                    echo "=== SSH 会话身份 ==="
                    id
                    echo "=== Java（JCasC javaPath）==="
                    /opt/java/openjdk/bin/java -version 2>&1
                    echo "=== DNS（dig @dnsmasq）==="
                    dig +short "home.${DOMAIN}" "@${IP_DNSMASQ}"
                '''
            }
        }
        stage('probe-agent') {
            steps {
                sh '/opt/orgflow/shared/bin/check-lan.sh jenkins-agent'
            }
        }
    }
    post {
        always { cleanWs() }
    }
}
