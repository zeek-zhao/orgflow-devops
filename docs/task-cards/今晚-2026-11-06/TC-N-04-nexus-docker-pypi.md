# [TC-N-04] Nexus Docker / PyPI 仓库与拉推实测

> **派工批次**：今晚 2026-11-06（用户 22:36 指令）。
> **本目录只有需求与验收，不含实现代码。** 另一个 AI 读 GitHub 上的这些卡片与挂起的
> Issue，自行建 PR 解决问题；派单方不代写实现。
> 全部归入 **M0**；**M1 #60 冻结**，到 M0 全绿且用户人工确认之后才解锁。
> Issue 是需求真本，卡片与 Issue 冲突时**以 Issue 为准**。

- **Issue**：**#117**（需求真本）
- **依赖**：无，可与 Jenkins 改造并行
- **用户裁决**：新增 `docker.` / `pypi.` 两条子域走 **Caddy 443**，宿主不直开端口

## 需求

「服务器」= hosted（私有），「代理」= proxy（上游缓存），按 Nexus 惯例再配 group 聚合：
`docker-hosted` / `docker-proxy` / `docker-group`，`pypi-hosted` / `pypi-proxy` / `pypi-group`。
然后**真的测拉和推**，不许用「应该可以」代替。

## 现状取证（见总览 README）

- Nexus `sonatype/nexus3:3.92.2`，现有 7 个仓库全是 maven2/nuget，无 docker、无 pypi。
- `of-nexus` 的 `8081/tcp` **未映射宿主**，只靠 Caddy 同网络反代
  （`docker run --network orgflow-devops_default --network-alias nexus --ip 172.31.0.21`）。
- 因此 Docker connector 端口可被 Caddy 同网络直连，**不需要改 `scripts/nexus-deploy.sh`
  的 `docker run` 参数**（避免重建丢配置）。
- `config/routes.yaml` 现有 7 个子域，新增 2 条要 `make render` 才生效。

## 验收（必须真跑，贴原始输出）

- [ ] `GET /service/rest/v1/repositories` 列出 6 个新仓库（贴输出）
- [ ] `docker login docker.org-devops.com` 成功
- [ ] `docker push` 一个真实镜像 → 删除本地 → `docker pull` 回来，**digest 一致**
- [ ] `pip download` 经 pypi proxy 成功；`twine upload` 到 pypi-hosted 成功，
      再 `pip install --index-url https://pypi.org-devops.com/simple` 装回来
- [ ] 反证：错误口令 push 必须 **401**
- [ ] 既有 7 个域名与 `docs` 路由不受影响；`make test` RC=0
- [ ] hosts 分发说明同步（`tools/win-acceptance/` 与文档，**条数 +2**）

## 边界

- 不改 `nexus-deploy.sh` 的容器端口映射，不重启 Nexus 数据卷。
- admin 密码只经环境变量 / `withCredentials` 注入，不落仓库与日志。
- **hosts 条数 +2** 会触发一次新的跨机浏览器验收：#65 已关，**另开记录，不重开 #65**。

## 派工铁律（每张卡都适用）

- 不改 `.env`（`deploy.sh` 有「已有 .env 绝不修改」约定）；凭据只用环境变量 / `withCredentials`。
- 不伪造通过：所有验收必须真跑并贴原始输出、run id、HTTP 码；不许写「应该可以」「预计通过」。
- 不为过测试放宽判据；发现夹具不匹配就**修夹具**，不是删断言。
- 不自行合并 PR；派工分支由派单方 `gh pr merge --rebase` 合并（禁止 squash）。
- author 恒为 `zeek.zhao <zeek.zhao@foxmail.com>`；commit message 含反引号时落文件用 `-F`。
- 不用 `--no-verify` 绕过 pre-push；rebase 后的既有分支换新分支名推送。
- `pre-push` 钩子在既有分支上会误扫 GitHub rebase 的 committer —— 换全新分支名，不是绕钩子。
- 每条关单评论必须附真实证据；**需要人工浏览器验收的项目不许自行关单**。
