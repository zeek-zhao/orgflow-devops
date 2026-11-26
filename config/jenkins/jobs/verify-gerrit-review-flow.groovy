// Job DSL：verify-gerrit-review-flow（M2.4 Phase3 功能级 Job）。
// 评审流（重）：建探针 change → 触发构建 → Verified +1 → abandon（默认 EXCLUDE，heavy）
// 流水线逻辑读 ci/jenkins/pipelines/verify-gerrit-review-flow.Jenkinsfile（内联，随 JCasC 重建）。
def pipelineText = new File('/opt/orgflow/ci/jenkins/pipelines/verify-gerrit-review-flow.Jenkinsfile').text

pipelineJob('verify-gerrit-review-flow') {
    description('评审流（重）：建探针 change → 触发构建 → Verified +1 → abandon（默认 EXCLUDE，heavy）')
    logRotator { daysToKeep(7); numToKeep(20) }
    definition {
        cps {
            script(pipelineText)
            sandbox()
        }
    }
}
