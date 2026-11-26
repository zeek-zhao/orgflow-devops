// Job DSL：Gerrit patchset 触发的构建 Job（M2.3.3）。
// 由 JCasC jobs: - file: 引用，随配置重载幂等生成。
// 触发由 gerrit-trigger 插件按 patchset-created 事件驱动（见 jenkins.yaml unclassified.gerritTrigger）。
// 流水线逻辑读 ci/jenkins/pipelines/build-from-gerrit.Jenkinsfile（分离，不内联）。
def pipelineText = new File('/opt/orgflow/ci/jenkins/pipelines/build-from-gerrit.Jenkinsfile').text

pipelineJob('build-from-gerrit') {
    description('Gerrit patchset → buildkit → push registry → Verified+1（M2.3）')
    logRotator { daysToKeep(14); numToKeep(30) }
    parameters {
        stringParam('SERVICE', 'cgit', '要构建的服务目录（services/<svc>）')
        stringParam('TARGET_TAG', '', '留空=按内容哈希生成 ctx-<12>')
    }
    // gerrit-trigger 事件参数：GERRIT_REFSPEC / GERRIT_CHANGE_NUMBER / GERRIT_PATCHSET_REVISION
    // 由插件随 patchset-created 事件注入；手动触发需自行填写。
    properties {
        pipelineTriggers {
            triggers {
                gerrit {
                    events {
                        patchsetCreated()
                    }
                    project('orgflow-devops', 'plain')
                    platform('git')
                    gerritBuildStartedVerified(true)
                    gerritBuildSuccessfulVerified(true)
                    gerritBuildFailedVerified(false)
                }
            }
        }
    }
    definition {
        cps {
            script(pipelineText)
            sandbox()
        }
    }
}
