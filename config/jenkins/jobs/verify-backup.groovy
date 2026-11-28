// Job DSL：verify-backup（M3.0.1 T2 备份可信校验 Job）。
// 只读消费宿主 /data/backups（挂到 agent /opt/orgflow/backups:ro），无 docker.sock。
// 四项断言：latest 新鲜≤26h + sha256 + manifest(9卷/entries>0) + status.exit_code=0。
def pipelineText = new File('/opt/orgflow/ci/jenkins/pipelines/verify-backup.Jenkinsfile').text

pipelineJob('verify-backup') {
    description('备份可信校验（M3.0.1 T2）：latest≤26h + sha256 + manifest 9卷 + status.exit_code=0；只读，无 docker.sock')
    logRotator { daysToKeep(7); numToKeep(20) }
    definition {
        cps {
            script(pipelineText)
            sandbox()
        }
    }
}
