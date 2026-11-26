// Job DSL：selfcheck —— 自检编排 Job（M2.4 Phase3）。
// 跑在 controller（agent none），编排用 build 步骤调子 Job 不占 agent；
// 文件读写（清单/报告）用 node('built-in') 块在 controller 的 workspace 内完成。
def pipelineText = new File('/opt/orgflow/ci/jenkins/pipelines/selfcheck.Jenkinsfile').text

pipelineJob('selfcheck') {
    description('自检编排（M2.4）：按 ci/selfcheck/checks.tsv 调子 Job + 生成自包含 HTML/JSON 报告。参数 INCLUDE/EXCLUDE/NEGATIVE/TIMEOUT_MIN。')
    logRotator { daysToKeep(14); numToKeep(20) }
    parameters {
        stringParam('INCLUDE', '', '逗号分隔的 id；留空=全部')
        stringParam('EXCLUDE', '', '逗号分隔要跳过的 id（如 feat-review-flow 跳过重项）')
        booleanParam('NEGATIVE', false, '演示报告失败态：强制第一条判 FAIL，不影响真实子 Job')
        stringParam('TIMEOUT_MIN', '20', '总超时（分钟）')
    }
    definition {
        cps {
            script(pipelineText)
            sandbox()
        }
    }
}
