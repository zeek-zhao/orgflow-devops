# Feature: 栈基线：镜像与服务拓扑

  行为真源：与 tests/bats/00_stack.bats 一一对应（scripts/check_bdd.py 校验）。
  规程见 docs/engineering/开发生命周期.md §测试先行。

Feature: 栈基线：镜像与服务拓扑
  @REQ-M0-D4

  @REQ-M0-D4
  Scenario: stack: locked images, ten services and Ubuntu build bases
    Given 镜像锁定清单与 compose 配置就绪
    When 逐一核对镜像引用与 Ubuntu 构建基
    Then 十个服务全部锁定到 digest，构建基一致

  @REQ-M0-D4
  Scenario: stack: every service on the orgflow network has a fixed IPv4
    Given orgflow 网络与 compose 配置就绪
    When 读取每服务的固定 IPv4 配置
    Then 每个服务都有唯一固定 IPv4 且与架构表一致
