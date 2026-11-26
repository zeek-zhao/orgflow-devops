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
                // ★ gerrit-trigger 3.x Job DSL：
                //   1) 事件块是 triggerOnEvents{}（旧 events{} 已废弃）；
                //   2) 必须显式 gerritProjects{}，空 <gerritProjects/> 时 Job 不响应任何事件
                //      （判据 B 实测：patchset 推了但 0 构建）；
                //   3) gerritProject 必须带 branches{} 或 disableStrictForbiddenFileVerification(false)，
                //      否则报 "the following options are required: disableStrictForbiddenFileVerification"；
                //   4) serverName=__ANY__ 走 gerrit-trigger.xml 中名为 "gerrit" 的 server。
                gerrit {
                    gerritProjects {
                        gerritProject {
                            compareType('PLAIN')
                            pattern('orgflow-devops')
                            disableStrictForbiddenFileVerification(false)
                            branches {
                                branch {
                                    compareType('PLAIN')
                                    pattern('main')
                                }
                            }
                        }
                    }
                    triggerOnEvents {
                        patchsetCreated()
                    }
                    // Verified 回写由 server 级 JCasC（jenkins.yaml gerrit-trigger.servers[].config）
                    // 与 Pipeline 内 SSH review 统一负责，Job DSL 不重复声明布尔字段。
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
