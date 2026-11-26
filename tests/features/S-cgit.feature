Feature: cgit 只读代码视图（M2.1）
  作为研发团队
  我要一个 Docker 化的 cgit 提供 Gerrit 裸库的只读 Web 视图
  以便不经登录即可浏览公开仓库，且不泄露敏感系统库

  Scenario: 容器与健康
    Given cgit 自建镜像由 CI 出 ctx-<12> tag 且钉在 images.lock
    When of-cgit 容器启动
    Then healthcheck healthy（bash /dev/tcp 探 nginx 80）

  Scenario: 公网入口
    Given Caddy :443 的 handle_path /cgit/* 反代到 cgit:80
    When 公网访问 https://<host>/cgit/
    Then 返回 200 且 virtual-root=/cgit/ 重建的链接可达

  Scenario: 白名单（防 All-Users 泄露）
    Given cgitrc 用 repo. 显式清单（include=/tmp/projects.conf）而非 scan-path/project-list
    And entrypoint refresh_list 排除 All-Projects.git/All-Users.git
    When 列表刷新
    Then /tmp/projects.conf 只含业务仓的 repo.url/repo.path，不含 All-Users.git
    And 名字含 All-Users 子串的业务仓不被误伤
    # 注：初版 project-list 单独使用实测无效（cgit 1.2.3 No repositories found），已纠正为 repo. 清单。

  Scenario: 敏感库不可浏览
    Given All-Users.git 存用户 SSH key/配置/邮箱
    When 访问 /cgit/All-Users.git
    Then 不返回该库内容（不在白名单）

  Scenario: clone 协议（2026-11-26 已修复，待新镜像上线）
    Given nginx 对 info/refs|git-upload-pack 走 git-http-backend（Dockerfile 装 git）
    When curl /cgit/<repo>.git/info/refs?service=git-upload-pack
    Then 返回 smart-http 协议包（application/x-git-upload-pack-advertisement）
    # 根因是 cgit.cgi 不处理 git 传输协议（非 Caddy 剥前缀）。已用一次性容器端到端验证：
    # info/refs 返回 advertisement、git clone 成功。新 tag ctx-e0643a8c475e 待 CI 构建推 GHCR 后上线。

  Scenario: 定时刷新
    Given entrypoint 每 5 分钟刷新 projects.conf（repo. 清单）
    And cgit-refresh.sh 可由 Jenkins Job 触发
    When 新增业务仓
    Then 列表在一个周期内包含新仓
