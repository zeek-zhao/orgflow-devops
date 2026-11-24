// Job DSL：生成 7 条 verify-<svc> 单服务探测 Job（M1）。
// 由 JCasC jobs: - file: 引用，随配置重载幂等重建；controller 已挂 /opt/orgflow/ci:ro。
// 流水线逻辑读 ci/jenkins/pipelines/verify-service.Jenkinsfile（不内联进本文件，保持分离）。
def pipelineText = new File('/opt/orgflow/ci/jenkins/pipelines/verify-service.Jenkinsfile').text

def services = ['dnsmasq', 'ldap', 'caddy', 'homepage', 'ldapadmin', 'router', 'jenkins']

services.each { svc ->
    pipelineJob("verify-${svc}") {
        description("局域网探测：${svc}（check-lan.sh ${svc}，在 orgflow-agent 上执行）")
        logrotate {
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
