# Feature: 引导脚本幂等性

  行为真源：与 tests/bats/32_bootstrap_scripts.bats 一一对应（scripts/check_bdd.py 校验）。
  规程见 docs/engineering/开发生命周期.md §测试先行。

Feature: 引导脚本幂等性
  @REQ-M0-B7
  @REQ-M0-D6

  @REQ-M0-B7
  @REQ-M0-D6
  Scenario: nexus-deploy: 容器已存在时重跑幂等——复用、不重建、不换 IP
    Given nexus 容器已存在
    When 重跑 nexus-deploy
    Then 复用容器，不重建不换 IP

  @REQ-M0-D6
  Scenario: gen-agent-key: 重跑幂等——四个密钥文件字节不变、权限不受影响
    Given agent 密钥已生成
    When 重跑 gen-agent-key
    Then 四个文件字节不变、权限不变

  @REQ-M0-D6
  Scenario: gen-hosts: 片段含全部十域名与指定 IP，--write 落地后 getent 可解析 (#117 #62)
    Given routes.yaml 十域名已配置
    When 生成 hosts 片段并 --write
    Then 片段含全部域名与 IP，getent 可解析
