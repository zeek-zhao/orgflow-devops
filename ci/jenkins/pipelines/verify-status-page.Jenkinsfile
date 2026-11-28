// 功能级探测（M2.4 Phase3）：verify-feature.sh status-page，在 orgflow-agent 执行。
// M3.0.1 T4：追加"报告与代码同源"断言；M3.0.2 T6：改真校验（commit/deployTag/tagCommit/consistent）。
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
                // M3.0.2 T6：只读 latest.json，三字段 commit/deployTag/tagCommit + consistent 必须齐全，
                // consistent=YES 且 commit==tagCommit（真同源，杜绝同源自证）。
                // 反证：用旧 checkout 报告（无 tag / tagCommit 指向旧 SHA）替换 latest.json 必 FAILURE。
                sh '''
                    set -uo pipefail
                    R=/opt/orgflow/reports/latest.json
                    rc=0
                    if [ ! -f "$R" ]; then echo "✗ 缺 $R"; rc=1; else
                      commit="$(jq -r '.commit // empty' "$R" 2>/dev/null)"
                      dtag="$(jq -r '.deployTag // empty' "$R" 2>/dev/null)"
                      tcommit="$(jq -r '.tagCommit // empty' "$R" 2>/dev/null)"
                      cons="$(jq -r '.consistent // empty' "$R" 2>/dev/null)"
                      echo "[同源] commit=$commit deployTag=$dtag tagCommit=$tcommit consistent=$cons"
                      [ -n "$commit" ] || { echo "✗ commit 空"; rc=1; }
                      [ -n "$dtag" ] || { echo "✗ deployTag 字段缺失（旧报告）"; rc=1; }
                      [ "$dtag" != "none" ] || { echo "✗ deployTag=none（HEAD 无匹配 tag）"; rc=1; }
                      [ -n "$tcommit" ] || { echo "✗ tagCommit 字段缺失（旧报告）"; rc=1; }
                      [ "$tcommit" != "unknown" ] || { echo "✗ tagCommit=unknown"; rc=1; }
                      [ "$cons" = "YES" ] || { echo "✗ consistent=$cons != YES"; rc=1; }
                      [ "$commit" = "$tcommit" ] || { echo "✗ commit=$commit != tagCommit=$tcommit"; rc=1; }
                    fi
                    exit "$rc"
                '''
            }
        }
        stage('report-freshness') {
            steps {
                // m3.0.5 T2（D1）：报告时效断言——latest.json 必须有 generated_at 且为合法 ISO8601；
                // HTML 必须内嵌同一时间串（供前端计算 age）。反证：删 generated_at → FAILURE。
                sh '''
                    set -uo pipefail
                    R=/opt/orgflow/reports/latest.json
                    H=/opt/orgflow/reports/latest.html
                    rc=0
                    [ -f "$R" ] || { echo "✗ 缺 $R"; exit 1; }
                    [ -f "$H" ] || { echo "✗ 缺 $H"; exit 1; }
                    gen="$(jq -r '.generated_at // empty' "$R" 2>/dev/null)"
                    genr="$(jq -r '.generator // empty' "$R" 2>/dev/null)"
                    echo "[时效] generated_at=$gen generator=$genr"
                    [ -n "$gen" ] || { echo "✗ generated_at 缺失（旧版本报告，请重跑 selfcheck）"; rc=1; }
                    [ -n "$genr" ] || { echo "✗ generator 缺失"; rc=1; }
                    # 可解析校验：agent 容器无 python3，用 GNU date -d 解析 ISO8601（Z→+00:00）。
                    if [ -n "$gen" ]; then
                      if date -d "${gen%Z}+00:00" +%s >/dev/null 2>&1; then
                        echo "[时效] generated_at 可解析 OK"
                      else
                        echo "✗ generated_at 不可解析: $gen"; rc=1
                      fi
                      # HTML 必须出现该时间串（前端据此计算 age）
                      grep -qF "$gen" "$H" || { echo "✗ HTML 未出现 generated_at 时间串 $gen"; rc=1; }
                    fi
                    exit "$rc"
                '''
            }
        }
    }
    post { always { cleanWs() } }
}
