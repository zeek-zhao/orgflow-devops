// Job DSL：verify-cgit-smart-http（M2.4 Phase3 功能级 Job）。
// 功能级探测：cgit-smart-http
// 流水线逻辑读 ci/jenkins/pipelines/verify-cgit-smart-http.Jenkinsfile（内联，随 JCasC 重建）。
def pipelineText = new File('/opt/orgflow/ci/jenkins/pipelines/verify-cgit-smart-http.Jenkinsfile').text

pipelineJob('verify-cgit-smart-http') {
    description('功能级探测：cgit-smart-http')
    logRotator { daysToKeep(7); numToKeep(20) }
    definition {
        cps {
            script(pipelineText)
            sandbox()
        }
    }
}
