# AGENTS.md

给 AI 编码助手的工作约定。**先读完本文件再动手**；规程层的细节（分工、验收责任、哪些活不能派）
在 [docs/AI-协作开发.md](docs/engineering/AI-协作开发.md)，改代码的路径在 [docs/工程开发说明.md](docs/engineering/开发生命周期.md)。

一句话：**这个仓库的每个结论都要能被一条命令复现**。写不出复现命令的改动，先别提交。

## 这是什么

一套单机自托管的 DevOps 平台（Caddy + oauth2-proxy + Dex + OpenLDAP + Jenkins + Nexus + dnsmasq），
用 `docker compose` 编排，镜像由 GitHub Actions 构建后推到 GHCR、本地只拉不构建。

## 改动前必读（按顺序，别跳）

1. [docs/requirements/](docs/requirements/)：要求什么、怎么算做到。**改行为前先找到对应的 `REQ-M0-xx`**。
2. [docs/工程开发说明.md](docs/engineering/开发生命周期.md)：目录语义与改一条 X 要动哪几个文件。
3. [docs/文档规范.md](docs/engineering/文档规范.md)：新增/删除文档必须登记，否则 `make docs-check` 红。

## 常跑命令

```bash
make check         # 快检查：文档配置 / 死链 / 脱敏 / 标签清单（几秒，无 docker；pre-commit 同款）
make check-all     # 快检查 + make test + lint + bats（pre-push 同款；SKIP_BATS=1 可跳 bats）
make test          # 静态 + 行为自检（python，无需 docker）
make test-bats     # 全栈行为（DinD，需要 docker，几分钟）
make docs-check    # 文档登记册双向一致
make links         # 仓内链接 0 死链
make redaction     # 公开面门禁：内网标识 / 凭据形态 / 内部文档
make lint          # shellcheck + yamllint（未安装会跳过）
```

提交前**至少**跑 `make check`；推之前跑 `make check-all`（或直接让钩子跑 —— `make hooks` 装一次即可）。
CI 上 `Compliance` / `Test` / `Identity` 三个工作流是必需检查，红着不合。

## 硬约束（违反会被门禁挡下，别试图绕过）

| 约束 | 谁在管 | 为什么 |
|---|---|---|
| author 与 committer 必须是 `zeek.zhao <zeek.zhao@foxmail.com>` | `.githooks/commit-msg`、`pre-push`、`make identity-check`、`Identity` 工作流 | 提交历史是审计证据，两个作者等于没人负责 |
| 禁止任何 AI 署名尾注（`Co-authored-by:` / `Generated with …` / 🤖） | 同上 | 同上 |
| 不得直接推 `main` | `pre-push` 钩子 + ruleset | 改动必须过 PR 与必需检查 |
| 合并用 **Rebase**，不用 Squash | 人工 | Squash 会产生 noreply 作者，下一次身份检查必红 |
| 不得改 `tests/images.lock` 里的 digest 来"修红" | 人工 + `images-guard` | digest 是「这份源码对应哪个镜像」的唯一锚点 |
| 不得为了让检查变绿而放宽断言或删用例 | 人工 review | 假绿比红更贵，历史上已经付过一次代价 |

## 不会做的事（写下来是因为被问过很多次）

- **不在本地构建镜像**。`make build-local` 只用于验证 Dockerfile 改动，产物**不推** GHCR。
  镜像由 CI 构建；本地 `make deploy` 默认 `USE_GHCR=1` 直接拉。
- **不手工 `docker run` 起 ldap / jenkins**。挂载点、`--env-file`、依赖顺序都在 compose 里，
  手工起的容器会缺 `/etc/passwd` 之类的挂载，表现为随机报错。
- **不把 `.env` 的真值写进任何文档、注释、测试夹具**。仓库只存占位符与 `{SSHA}` 哈希。
- **不改历史**。重写历史会让所有 PR 引用失效、CI 缓存错位；只有「公开前的密钥清理」这种一次性
  事件才做过，且必须同时更新 `# pinned-at`。

## 遇到红怎么办

1. **先取证再改**。红的原因分三类：真缺陷 / 判据没跟上变化（假红）/ 环境差异。
   三类改法完全不同，猜错会引入第二个问题。
2. 假红（比如「Windows 上耗时门禁被超时杀掉」）**必须修门禁**，不是加 `|| true`。
3. 修完要贴**反证**：改坏一处 → 门禁必须红；恢复 → 绿。只贴绿的那半不算验证。
4. 三条以上同源失败，先停下来写清楚根因，不要逐个打补丁。

## 提交消息

```
type(area): 一句话说清改了什么

为什么改、代价是什么、怎么验证的。diff 已经说了「改了什么」，正文只说「为什么」。
```

`type` 取 `feat|fix|docs|ci|refactor|test|chore`；`area` 取 `identity|pipeline|presentation|ops|compliance|docs|project`。
