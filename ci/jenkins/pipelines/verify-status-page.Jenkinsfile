// 功能级探测（M2.4 Phase3）：verify-feature.sh status-page，在 orgflow-agent 执行。
// M3.0.1 T4：追加"报告与代码同源"断言（latest.json 的 commit/deployedHead/consistent）。
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
                        /opt/orgflow/shared/bin/verify-feature.sh status-page
                    """
                }
            }
        }
        stage('report-consistency') {
            steps {
                // 只读 latest.json：必须含 deployedHead/consistent，consistent=YES，且 commit==deployedHead。
                // 反证：用旧 commit 报告替换 latest.json 必 FAILURE。
                sh '''
                    set -uo pipefail
                    R=/opt/orgflow/reports/latest.json
                    rc=0
                    if [ ! -f "$R" ]; then echo "✗ 缺 $R"; rc=1; else
                      commit="$(jq -r '.commit // empty' "$R" 2>/dev/null)"
                      dep="$(jq -r '.deployedHead // empty' "$R" 2>/dev/null)"
                      cons="$(jq -r '.consistent // empty' "$R" 2>/dev/null)"
                      echo "[同源] commit=$commit deployedHead=$dep consistent=$cons"
                      [ -n "$commit" ] || { echo "✗ commit 空"; rc=1; }
                      [ -n "$dep" ] || { echo "✗ deployedHead 字段缺失（旧报告）"; rc=1; }
                      [ "$cons" = "YES" ] || { echo "✗ consistent=$cons != YES"; rc=1; }
                      [ "$commit" = "$dep" ] || { echo "✗ commit=$commit != deployedHead=$dep"; rc=1; }
                    fi
                    exit "$rc"
                '''
            }
        }
    }
    post { always { cleanWs() } }
}
