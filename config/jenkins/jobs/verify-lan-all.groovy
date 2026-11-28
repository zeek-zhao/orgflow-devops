// Job DSL：verify-lan-all —— 并行跑全部服务探测并生成 Markdown 汇总表（M1）。
def pipelineText = new File('/opt/orgflow/ci/jenkins/pipelines/verify-lan-all.Jenkinsfile').text

pipelineJob('verify-lan-all') {
    description('全服务局域网检测：并行探测 DNS/LDAP/Caddy/HomePage/LDAPAdmin/Router/Jenkins/JenkinsAgent/Gerrit/Cgit 共 10 项，输出 lan-report.md')
    logRotator {
        daysToKeep(7)
        numToKeep(30)
    }
    // M3.0.3 T6：删除每日 02:xx cron（服务随时关停，长定时无意义）；由 selfcheck 显式调用/手动触发。
    definition {
        cps {
            script(pipelineText)
            sandbox()
        }
    }
}
