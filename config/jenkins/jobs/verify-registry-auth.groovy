// Job DSL：verify-registry-auth（M2.4 Phase3 功能级 Job）。
// 功能级探测：registry-auth
// 流水线逻辑读 ci/jenkins/pipelines/verify-registry-auth.Jenkinsfile（内联，随 JCasC 重建）。
def pipelineText = new File('/opt/orgflow/ci/jenkins/pipelines/verify-registry-auth.Jenkinsfile').text

pipelineJob('verify-registry-auth') {
    description('功能级探测：registry-auth')
    logRotator { daysToKeep(7); numToKeep(20) }
    definition {
        cps {
            script(pipelineText)
            sandbox()
        }
    }
}
