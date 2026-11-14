# Feature: Jenkins API token 与 CLI 四件套
  行为真源：与 tests/bats/40_jenkins_cli_token.bats 一一对应（scripts/check_bdd.py 校验）。
  规程见 docs/engineering/开发生命周期.md §测试先行。
Feature: Jenkins API token 与 CLI 四件套
  @REQ-M0-B4
  Scenario: jenkins: API token 生命周期——生成→认证→错 token 401→撤销后 401
    Given svc-platform-admin 可经 LDAP 凭据登录并持有 crumb
    When 生成 API token 后用它认证，再用错误 token 与撤销后的 token 认证
    Then 新 token 认证成功，错误 token 与撤销后的 token 都必须 401
  @REQ-M0-B4
  Scenario: jenkins: CLI 四件套用 API token 真跑——list/get/run/log(专用夹具+清理)
    Given API token 已生成且参数化夹具 Job 已创建并绑定 orgflow-docker 标签
    When 用 token 依次执行 list/get/run/log 四个子命令并轮询日志
    Then 四步全部成功且日志出现夹具 echo 的参数内容，用例结束后夹具与 token 不复存在
