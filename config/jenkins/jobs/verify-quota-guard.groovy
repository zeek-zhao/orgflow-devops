// Job DSL：verify-quota-guard（M2.5 P0 功能级 Job）。
// 只读消费宿主 quota-guard 证据，不需要 docker socket。
def pipelineText = new File('/opt/orgflow/ci/jenkins/pipelines/verify-quota-guard.Jenkinsfile').text

pipelineJob('verify-quota-guard') {
    description('功能级探测：构建资源配额证据（verdict=PASS / of-builder / 三项配额 0；只读证据，无 docker.sock）')
    logRotator { daysToKeep(7); numToKeep(20) }
    definition {
        cps {
            script(pipelineText)
            sandbox()
        }
    }
}
