// 功能级探测（M2.4 Phase3）：verify-feature.sh registry-auth，在 orgflow-agent 执行。
// 凭据经 Jenkins withCredentials 注入 env，不进命令行/console。
pipeline {
    agent { label 'orgflow-agent' }
    options { timestamps(); timeout(time: 5, unit: 'MINUTES') }
    stages {
        stage('feature') {
            steps {
                withCredentials([
                  string(credentialsId: 'ldap-admin-password', variable: 'LDAP_BIND_PASSWORD'),
                  usernamePassword(credentialsId: 'registry-ci', usernameVariable: 'REGISTRY_CI_USER', passwordVariable: 'REGISTRY_CI_PASSWORD')
                ]) {
                    sh """
                        /opt/orgflow/shared/bin/verify-feature.sh registry-auth
                    """
                }
            }
        }
    }
    post { always { cleanWs() } }
}
