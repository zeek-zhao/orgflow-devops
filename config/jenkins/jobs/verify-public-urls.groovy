// Job DSL：verify-public-urls（M2.4 Phase3 功能级 Job）。
// 功能级探测：public-urls
// 流水线逻辑读 ci/jenkins/pipelines/verify-public-urls.Jenkinsfile（内联，随 JCasC 重建）。
def pipelineText = new File('/opt/orgflow/ci/jenkins/pipelines/verify-public-urls.Jenkinsfile').text

pipelineJob('verify-public-urls') {
    description('功能级探测：public-urls')
    logRotator { daysToKeep(7); numToKeep(20) }
    definition {
        cps {
            script(pipelineText)
            sandbox()
        }
    }
}
