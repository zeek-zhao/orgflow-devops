// Job DSL：verify-restore-drill（M3.0.1 T3 隔离恢复演练结果校验 Job）。
// 只读消费宿主 drill 结果（agent 挂 /data/drill:ro 与 /data/drill-logs:ro），无 docker.sock。
// 每周日 04:30（H 4 * * 0）跑一次，避开 03:00 评审流与 03:30 备份。
def pipelineText = new File('/opt/orgflow/ci/jenkins/pipelines/verify-restore-drill.Jenkinsfile').text

pipelineJob('verify-restore-drill') {
    description('隔离恢复演练结果校验（M3.0.1 T3）：drill.result=PASS + 四项断言日志 + 新鲜≤8d + 资源守卫；离线只读，无 docker.sock')
    logRotator { daysToKeep(7); numToKeep(20) }
    triggers { cron('H 4 * * 0') }
    definition {
        cps {
            script(pipelineText)
            sandbox()
        }
    }
}
