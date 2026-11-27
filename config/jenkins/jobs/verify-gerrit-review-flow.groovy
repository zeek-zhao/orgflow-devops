// Job DSL：verify-gerrit-review-flow（M2.4 Phase3 功能级 Job）。
// 评审流（重）：建探针 change → 触发构建 → Verified +1 → abandon（默认 EXCLUDE，heavy）
// 流水线逻辑读 ci/jenkins/pipelines/verify-gerrit-review-flow.Jenkinsfile（内联，随 JCasC 重建）。
def pipelineText = new File('/opt/orgflow/ci/jenkins/pipelines/verify-gerrit-review-flow.Jenkinsfile').text

pipelineJob('verify-gerrit-review-flow') {
    description('评审流（重）：建探针 change → 触发构建 → Verified +1 → abandon（默认 EXCLUDE，heavy）')
    logRotator { daysToKeep(7); numToKeep(20) }
    // m2.5.5 P1-2：heavy 评审流此前"默认跳过、由单独定时任务执行"是空话——JCasC 里没有任何
    // cron/定时配置。补每天 03:xx（H 抖动）自动跑一次，自检报告顶部注明的结果查看位置才成立。
    triggers { cron('H 3 * * *') }
    definition {
        cps {
            script(pipelineText)
            sandbox()
        }
    }
}
