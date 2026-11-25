// Job DSL：verify-lan-all —— 并行跑全部服务探测并生成 Markdown 汇总表（M1）。
def pipelineText = new File('/opt/orgflow/ci/jenkins/pipelines/verify-lan-all.Jenkinsfile').text

pipelineJob('verify-lan-all') {
    description('全服务局域网检测：并行探测 DNS/LDAP/Caddy/HomePage/LDAPAdmin/Router/Jenkins/JenkinsAgent 共 8 项，输出 lan-report.md')
    logRotator {
        daysToKeep(7)
        numToKeep(30)
    }
    // E1：每日 02:xx 随机分钟定时巡检；H 让负载分散，手动触发仍保留（pipelineJob 默认可手动构建）。
    triggers {
        cron('H 2 * * *')
    }
    definition {
        cps {
            script(pipelineText)
            sandbox()
        }
    }
}
