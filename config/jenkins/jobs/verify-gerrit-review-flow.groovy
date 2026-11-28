// Job DSL：verify-gerrit-review-flow（M2.4 Phase3 功能级 Job）。
// 评审流（重）：建探针 change → 触发构建 → Verified +1 → abandon（默认 EXCLUDE，heavy）
// 流水线逻辑读 ci/jenkins/pipelines/verify-gerrit-review-flow.Jenkinsfile（内联，随 JCasC 重建）。
def pipelineText = new File('/opt/orgflow/ci/jenkins/pipelines/verify-gerrit-review-flow.Jenkinsfile').text

pipelineJob('verify-gerrit-review-flow') {
    description('评审流（重）：建探针 change → 触发构建 → Verified +1 → abandon（默认 EXCLUDE，heavy）')
    logRotator { daysToKeep(7); numToKeep(20) }
    // M3.0.3 T6（E1）：删除每天凌晨的调度触发器。理由同演练：服务会被关停，夜间定时没有意义，
    // 还会留下"未观测"的记录。评审流由 selfcheck 显式触发或人工手动触发。
    definition {
        cps {
            script(pipelineText)
            sandbox()
        }
    }
}
