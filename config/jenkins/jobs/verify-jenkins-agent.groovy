// Job DSL：verify-jenkins-agent —— 验证 agent 节点本身（真实 SSH 会话用户 + 工具链）（M1）。
def pipelineText = new File('/opt/orgflow/ci/jenkins/pipelines/verify-jenkins-agent.Jenkinsfile').text

pipelineJob('verify-jenkins-agent') {
    description('验证 orgflow-agent：SSH 会话用户 jenkins(uid1000)、java/dig/ldapsearch/curl 可用')
    logRotator {
        daysToKeep(7)
        numToKeep(20)
    }
    definition {
        cps {
            script(pipelineText)
            sandbox()
        }
    }
}
