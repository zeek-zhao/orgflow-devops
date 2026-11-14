# Feature: Jenkins 构建节点

  行为真源：与 tests/bats/23_jenkins_agent.bats 一一对应（scripts/check_bdd.py 校验）。
  规程见 docs/engineering/开发生命周期.md §测试先行。

Feature: Jenkins 构建节点
  @REQ-M0-B6
  @REQ-M0-D7

  @REQ-M0-B6
  Scenario: jenkins-agent: 容器健康、固定 IP、docker CLI 真能用
    Given agent 容器已运行
    When 检查健康/IP 并在容器内跑 docker CLI
    Then healthy、固定 IP、docker 可用

  @REQ-M0-B6
  @REQ-M0-D7
  Scenario: jenkins-agent: JCasC 建出的节点在线，且带 orgflow-docker 标签
    Given JCasC 已应用
    When 查询节点状态与标签
    Then 节点在线且带 orgflow-docker 标签

  @REQ-M0-B6
  Scenario: jenkins-agent: JCasC 把 SSH 私钥装进了系统凭据库
    Given JCasC 已应用
    When 查询系统凭据库
    Then SSH 私钥凭据存在
