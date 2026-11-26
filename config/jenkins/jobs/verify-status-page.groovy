// Job DSL：verify-status-page（M2.4 Phase3 功能级 Job）。
// 功能级探测：status-page
// 流水线逻辑读 ci/jenkins/pipelines/verify-status-page.Jenkinsfile（内联，随 JCasC 重建）。
def pipelineText = new File('/opt/orgflow/ci/jenkins/pipelines/verify-status-page.Jenkinsfile').text

pipelineJob('verify-status-page') {
    description('功能级探测：status-page')
    logRotator { daysToKeep(7); numToKeep(20) }
    definition {
        cps {
            script(pipelineText)
            sandbox()
        }
    }
}
