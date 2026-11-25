// Job DSL：生成 8 条 verify-<svc> 单服务探测 Job（M1）。
// 由 JCasC jobs: - file: 引用，随配置重载幂等重建；controller 已挂 /opt/orgflow/ci:ro。
// 流水线逻辑读 ci/jenkins/pipelines/verify-service.Jenkinsfile（不内联进本文件，保持分离）。
def pipelineText = new File('/opt/orgflow/ci/jenkins/pipelines/verify-service.Jenkinsfile').text

// r5 §4-2：服务清单以 services/manifest.tsv 为真源（scripts/check-service-list.sh 校验此处不得漂移）。
// 8 项 = manifest 排除一次性 certs-init；含 jenkins-agent 自身断言（此前误写 7 项导致漂移）。
def services = ['dnsmasq', 'ldap', 'caddy', 'homepage', 'ldapadmin', 'router', 'jenkins', 'jenkins-agent']

services.each { svc ->
    pipelineJob("verify-${svc}") {
        description("局域网探测：${svc}（check-lan.sh ${svc}，在 orgflow-agent 上执行）")
        logRotator {
            daysToKeep(7)
            numToKeep(20)
        }
        parameters {
            stringParam('SERVICE', svc, '要探测的服务名（一般保持默认）')
        }
        definition {
            cps {
                script(pipelineText)
                sandbox()
            }
        }
    }
}
