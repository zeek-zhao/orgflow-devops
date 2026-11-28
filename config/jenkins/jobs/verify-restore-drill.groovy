// Job DSL：verify-restore-drill（M3.0.3 T1/T2）：隔离恢复演练结果校验 Job。
// 只读消费宿主 drill 结果（agent 挂 /data/drill:ro 与 /data/drill-logs:ro），无 docker.sock。
// M3.0.3 T1（E1）：删除每周 cron，改纯手动（演练是封版前人工动作，不是定时任务）。
// 由 make drill 手动起栈产出结果后，手动触发本 Job 做离线字段化校验。
def pipelineText = new File('/opt/orgflow/ci/jenkins/pipelines/verify-restore-drill.Jenkinsfile').text

pipelineJob('verify-restore-drill') {
    description('隔离恢复演练结果校验（手动）：result=PASS + healthy=3 + repos=3 + P_open=D_open + P_total=D_total + backup_sha256 一致 + mode 合法；年龄仅信息不判红；离线只读，无 docker.sock')
    logRotator { daysToKeep(7); numToKeep(20) }
    // M3.0.3 T1：无 triggers —— 仅手动触发（selfcheck 已移除 data-drill 默认项）。
    definition {
        cps {
            script(pipelineText)
            sandbox()
        }
    }
}
