Feature: registry:2 轻量镜像仓库（M2.2）
  作为研发团队
  我要一个带基础鉴权的 OCI/Docker 镜像仓库
  以便在项目内 push/pull 构建产物，而不引入 Harbor 全栈的内存开销

  Scenario: 镜像与编排登记
    Given registry 薄封装 FROM registry:2@digest + apache2-utils
    And tag 为 ctx-<12>（image-hash.sh registry 前 12 位），钉在 images.lock（HASHED）
    And Check-service-list 探测集为 11 项（含 registry）
    Then make check / check-all 门禁全绿

  Scenario: 容器与健康
    Given of-registry 容器固定 IP 192.168.90.20，数据/鉴权卷外挂
    When 容器启动（entrypoint 用 htpasswd -B 渲染 /auth/htpasswd）
    Then healthcheck healthy（wget /v2/ 抓 Docker-Distribution 头）
    And /auth/htpasswd 模式 600，凭据不入库

  Scenario: 公网入口
    Given Tailscale Funnel :10000 → 回环 127.0.0.1:18086 → registry:5000（不经 Caddy）
    When curl -k https://<host>:10000/v2/
    Then 返回 401 + Docker-Distribution-API-Version 头（鉴权生效且存活）

  Scenario: push/pull 闭环
    Given docker login <host>:10000 用 admin/口令成功
    When docker push <host>:10000/demo:v1
    Then docker pull 同 tag 成功且 digest 一致
    # 待镜像 CI 构建上线后实测；骨架阶段标待办，不虚报。

  Scenario: 鉴权拒绝匿名
    Given 未登录客户端
    When docker pull <host>:10000/demo:v1
    Then 被 401 拒绝（401 Unauthorized: authentication required）
