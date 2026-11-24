// Job DSL：verify-lan-all —— 并行跑全部服务探测并生成 Markdown 汇总表（M1）。
def pipelineText = new File('/opt/orgflow/ci/jenkins/pipelines/verify-lan-all.Jenkinsfile').text

pipelineJob('verify-lan-all') {
    description('全服务局域网检测：并行探测 DNS/LDAP/Caddy/HomePage/LDAPAdmin/Router/Jenkins，输出 lan-report.md')
    logrotate {
        daysToKeep(7)
        numToKeep(30)
    }
    definition {
        cps {
            script(pipelineText)
            sandbox()
        }
    }
}
