// Gerrit patchset → buildkit build+push → registry 校验 → 回写 Verified（M2.3.3）。
// 在 orgflow-agent 执行：无 docker.sock，构建经 BUILDKIT_HOST=tcp://builder:1234 提交。
// 凭据（均不入库，JCasC env 注入）：
//   gerrit-ci-ssh  : ci-bot ed25519 私钥（checkout + SSH review 回写）
//   registry-ci    : registry 用户名/口令（usernamePassword，生成临时 docker config 供 buildctl 推）
// 失败绝不回写 Verified（post.failure 只记录），避免假绿。
pipeline {
    agent { label 'orgflow-agent' }
    options {
        timestamps()
        timeout(time: 20, unit: 'MINUTES')
        skipDefaultCheckout(true)
    }
    parameters {
        string(name: 'SERVICE', defaultValue: 'cgit', description: '要构建的服务目录（services/<svc>），默认 cgit（体积小）')
        string(name: 'TARGET_TAG', defaultValue: '', description: '留空=按内容哈希生成 ctx-<12>')
    }
    environment {
        BUILDKIT_HOST = 'tcp://builder:1234'
        // M2.3 收口 P2-3：用 compose 服务名而非硬编码 IP（orgflow 内网 DNS 可解析 registry）。
        // buildkitd.toml 已声明 registry:5000 为 insecure HTTP，push 无需改协议。
        REGISTRY      = 'registry:5000'
    }
    stages {
        stage('Checkout change') {
            steps {
                withCredentials([sshUserPrivateKey(credentialsId: 'gerrit-ci-ssh', keyFileVariable: 'GERRIT_KEY')]) {
                    sh '''
                        set -e
                        echo "SERVICE=${SERVICE} GERRIT_CHANGE_NUMBER=${GERRIT_CHANGE_NUMBER:-} GERRIT_PATCHSET_NUMBER=${GERRIT_PATCHSET_NUMBER:-} GERRIT_PATCHSET_REVISION=${GERRIT_PATCHSET_REVISION:-}"
                        : "${GERRIT_REFSPEC:?GERRIT_REFSPEC 未注入（需 gerrit-trigger 事件参数）}"
                        rm -rf src && mkdir src && cd src
                        git init -q
                        git -c core.sshCommand="ssh -i $GERRIT_KEY -o StrictHostKeyChecking=no" \
                            fetch -q --depth=1 ssh://ci-bot@gerrit:29418/orgflow-devops "$GERRIT_REFSPEC"
                        git checkout -q FETCH_HEAD
                    '''
                }
            }
        }
        stage('Resolve tag') {
            steps {
                script {
                    def svc = params.SERVICE ?: 'cgit'
                    def hash = sh(script: "cd src && bash scripts/image-hash.sh ${svc}", returnStdout: true).trim()
                    env.IMG = params.TARGET_TAG ?: "${REGISTRY}/orgflow/m2-${svc}:ctx-${hash.take(12)}"
                    echo "IMG=${IMG}"
                }
            }
        }
        stage('Build & push') {
            steps {
                withCredentials([usernamePassword(credentialsId: 'registry-ci', usernameVariable: 'RU', passwordVariable: 'RP')]) {
                    sh '''
                        set -e
                        # agent 镜像无 python3：用纯 shell + base64 生成 registry 的 docker config.json
                        export DOCKER_CONFIG="$(mktemp -d)"
                        trap 'rm -rf "$DOCKER_CONFIG"' EXIT
                        AUTH="$(printf '%s:%s' "$RU" "$RP" | base64 | tr -d '\n')"
                        printf '{"auths":{"%s":{"auth":"%s"}}}' "$REGISTRY" "$AUTH" > "$DOCKER_CONFIG/config.json"
                        buildctl build \
                          --frontend dockerfile.v0 \
                          --local context="src/services/${SERVICE}" \
                          --local dockerfile="src/services/${SERVICE}" \
                          --output "type=image,name=${IMG},push=true"
                    '''
                }
            }
        }
        stage('Verify in registry') {
            steps {
                withCredentials([usernamePassword(credentialsId: 'registry-ci', usernameVariable: 'RU', passwordVariable: 'RP')]) {
                    sh '''
                        set -e
                        TAG="${IMG##*:}"
                        curl -fsS -u "$RU:$RP" \
                          "http://${REGISTRY}/v2/orgflow/m2-${SERVICE}/manifests/${TAG}" \
                          -H 'Accept: application/vnd.docker.distribution.manifest.v2+json' -o /dev/null
                        echo "manifest ${IMG} 已在 registry 校验通过"
                    '''
                }
            }
        }
        stage('Verified +1') {
            steps {
                withCredentials([sshUserPrivateKey(credentialsId: 'gerrit-ci-ssh', keyFileVariable: 'GERRIT_KEY')]) {
                    sh '''
                        set -e
                        : "${GERRIT_CHANGE_NUMBER:?}"
                        : "${GERRIT_PATCHSET_REVISION:?}"
                        # M2.3 收口：Gerrit 3.9 的 `gerrit review` 必须带 patchset 序号：
                        #   gerrit review <change>,<patchset#>
                        # 传 revision hash 或省略 patchset 都报 "<n>" is not a valid patch set。
                        # gerrit-trigger 注入 GERRIT_PATCHSET_NUMBER（1/2/...）；缺失时回退 1。
                        : "${GERRIT_PATCHSET_NUMBER:=1}"
                        REV8="$(printf '%s' "$GERRIT_PATCHSET_REVISION" | cut -c1-8)"
                        ssh -i "$GERRIT_KEY" -o StrictHostKeyChecking=no -p 29418 ci-bot@gerrit \
                          "gerrit review ${GERRIT_CHANGE_NUMBER},${GERRIT_PATCHSET_NUMBER} \
                           --verified +1 --message 'CI: image ${IMG} built & pushed (rev ${REV8})'"
                    '''
                }
            }
        }
    }
    post {
        failure {
            echo "构建失败——Verified 不回写（不假绿）。SERVICE=${params.SERVICE}"
        }
        always { cleanWs() }
    }
}
