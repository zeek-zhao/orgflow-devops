# [TC-N-01] Jenkins 插件集、dark 默认主题、禁止自动更新与 CI 镜像链路修复

> **派工批次**：今晚 2026-11-06（用户 22:36 指令）。
> **本目录只有需求与验收，不含实现代码。** 另一个 AI 读 GitHub 上的这些卡片与挂起的
> Issue，自行建 PR 解决问题；派单方不代写实现。
> 全部归入 **M0**；**M1 #60 冻结**，到 M0 全绿且用户人工确认之后才解锁。
> Issue 是需求真本，卡片与 Issue 冲突时**以 Issue 为准**。

- **Issue**：**#115**（需求真本）
- **依赖**：无。**本卡是其余 Jenkins 卡的前置，必须最先合入 main 以触发 CI。**
- **归并**：#104 的 `check-pins` 占位由本卡解掉；认证切 LDAP 归 TC-N-02，不在本卡。

## 需求

1. **Pipeline Overview**：装 `pipeline-graph-view` 与 `pipeline-stage-view`（不是 Blue Ocean）。
2. **dark 主题**：装 `dark-theme`，并**设置全局默认主题为 dark**（不只是装插件）。
3. 装齐：`gerrit-trigger`、`tap`、`ssh-agent`、`docker-plugin`、`docker-workflow`、
   `build-monitor-plugin`、`throttle-concurrents`、`timestamper`、`ws-cleanup`。
4. **禁止 Jenkins 及其插件自动更新**：镜像 digest 钉死 + 插件逐项钉版本 + 机器可查的静态闸门。
   Jenkins 本体 war 在镜像里不会自动更新；真正会漂的是重建镜像时 `jenkins-plugin-cli` 拉到的版本。
   **不要写一个未经实测的 JVM 参数假装关掉了更新检查**；UI 提示属展示层，可另立单。
5. 装回 `timestamper` 后，把 #93 当初因插件缺失而删掉的 `options { timestamps() }`
   **恢复进 6 个 Job**，并同步更新静态检查的 options 白名单（反证换成不存在的 option 名）。

## 必须先修的 3 处 CI 缺陷（见总览 README 的取证表）

1. `select-images.sh` 的 `jenkins` context → `services/jenkins`；
2. `images.yml` 的 `paths` 补 `services/jenkins/**`（push 与 pull_request 两处）；
3. `metadata-action` 给 jenkins 单独打 `24.04-v3`，**不覆盖 `24.04-v1`**；
   `scripts/pin-images.sh` / `tests/images.sh` 同步。

## 验收

- [ ] `make test` RC=0、`make check-jenkins-image` RC=0
- [ ] 合入 main 后 `images.yml` 被 push 触发且 conclusion=success（贴 run id）
- [ ] `docker buildx imagetools inspect ghcr.io/.../jenkins:24.04-v3` 拿到真实 digest
- [ ] `tests/images.lock` 与 `docker-compose.ghcr.yml` 回填真实 sha256，`make check-pins` RC=0
- [ ] 部署后 `/pluginManager/api/json?depth=1` 逐项可见且 active；dark 默认主题在浏览器里生效
- [ ] 6 个 Job 恢复 `timestamps()` 后编译通过（贴构建结果）
- [ ] **反证**：`plugins.txt` 里塞一个裸 id 或 `latest` → 静态闸门必须红

## 禁止事项

- 不得编造 sha256、跳过 CI 手工填 digest、让 CI 覆盖 `24.04-v1` tag
- 不得把插件版本写成 `latest`；不得为过测试删掉 `test_job_pipelines.py` 的 options 白名单判据
- 不得把 `pipeline-graph-view` 钉成 `1101.v86fd4564c864`（需 core 2.589，现网 2.580.2）
- Gerrit Trigger **只装插件、不接真实服务器**（用户裁决），文档里必须明写「未接端点」

## 派工铁律（每张卡都适用）

- 不改 `.env`（`deploy.sh` 有「已有 .env 绝不修改」约定）；凭据只用环境变量 / `withCredentials`。
- 不伪造通过：所有验收必须真跑并贴原始输出、run id、HTTP 码；不许写「应该可以」「预计通过」。
- 不为过测试放宽判据；发现夹具不匹配就**修夹具**，不是删断言。
- 不自行合并 PR；派工分支由派单方 `gh pr merge --rebase` 合并（禁止 squash）。
- author 恒为 `zeek.zhao <zeek.zhao@foxmail.com>`；commit message 含反引号时落文件用 `-F`。
- 不用 `--no-verify` 绕过 pre-push；rebase 后的既有分支换新分支名推送。
- `pre-push` 钩子在既有分支上会误扫 GitHub rebase 的 committer —— 换全新分支名，不是绕钩子。
- 每条关单评论必须附真实证据；**需要人工浏览器验收的项目不许自行关单**。
