// Job DSL：verify-quota-refresh（m2.5.3 P0-2 刷新机制存活校验 Job）。
// 只读消费宿主 quota-guard-loop.sh 写的 alive.json + 证据，不需要 docker socket。
def pipelineText = new File('/opt/orgflow/ci/jenkins/pipelines/verify-quota-refresh.Jenkinsfile').text

pipelineJob('verify-quota-refresh') {
    description('刷新机制存活校验（m2.5.3）：进程命令行匹配 + 日志新鲜≤8min + 证据 age≤10min；只读证据，无 docker.sock')
    logRotator { daysToKeep(7); numToKeep(20) }
    definition {
        cps {
            script(pipelineText)
            sandbox()
        }
    }
}
