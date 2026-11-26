// Job DSL：verify-jenkins-theme（M2.4 Phase3 功能级 Job）。
// 功能级探测：jenkins-theme
// 流水线逻辑读 ci/jenkins/pipelines/verify-jenkins-theme.Jenkinsfile（内联，随 JCasC 重建）。
def pipelineText = new File('/opt/orgflow/ci/jenkins/pipelines/verify-jenkins-theme.Jenkinsfile').text

pipelineJob('verify-jenkins-theme') {
    description('功能级探测：jenkins-theme')
    logRotator { daysToKeep(7); numToKeep(20) }
    definition {
        cps {
            script(pipelineText)
            sandbox()
        }
    }
}
