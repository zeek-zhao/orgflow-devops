# AI 会话清单

> **读者**：在本仓库干活的 AI agent（以及想按同样纪律干活的人）。
> 这是**开工 SOP**：一个会话从拿到任务到合并收尾，每一步该做什么、什么不能碰。
> 工程背景与陷阱细节不在本文——先读 [会话交接](会话交接.md)，本文只管流程。

---

## 1. 开工清单（按序执行，任何一步不符先停下来弄清）

```sh
git fetch origin && git log -1 --format=%h          # 与 会话交接.md 的基线对不上？先看差了什么
git status --short                                  # 必须干净；有遗留改动先问清楚再动
make test                                           # 静态自检（文档链接 / IP 表 / 脚本逻辑），~10s
make identity-check                                 # 全历史身份扫描；红了先看 交接.md §4.6
gh pr list --state open                             # open PR 数与会话交接.md §0 对照
gh run list --limit 3                               # main 上 CI 必须 success
gh issue list --state open                          # 与 待办.md 对照，找出本次任务对应的卡
```

- [ ] 读了 [会话交接](会话交接.md) §0（三十秒版本）和 §4 里与本次任务相关的陷阱
- [ ] 本次任务在 Issue 里有卡（**Issue 是需求真本**，见 [派单流程](派单流程.md)）；没有就先开卡
- [ ] 确认这张卡没被别的卡卡住（`blocked-by` / 待办.md 的「卡在哪」列）
- [ ] `git config user.email` → `zeek.zhao@foxmail.com`（硬约束，见 §3）

## 2. 工作循环

```
开卡 → 建分支 → 改代码/文档 → make test → 提交 → push → PR → CI 绿 → rebase 合并 → 同步文档 → 关卡
```

1. **先建分支再改文件**：`git checkout -b <type>/<slug> origin/main`。
   在别人 PR 的检出上直接改文件，checkout/reset 会把工作区冲掉（踩过，见 验收记录 §12）。
2. **分支命名**：`feat/…` `fix/…` `docs/…` `test/…` `chore/…`，对齐已有分支。
3. **提交**：author 恒为 `zeek.zhao <zeek.zhao@foxmail.com>`；消息不带
   `Co-authored-by` / `Signed-off-by` / AI 署名（钩子 + `identity.yml` 会拦）。
4. **提交前**：`make test`；改了 compose 记得 `bash scripts/check-arch-ips.sh`；
   新增 `docs/*.md` 必须进 [README](../README.md) 索引（自检会红）。
5. **PR 描述**：写「做了什么 / 为什么 / 怎么验的 / 诚实声明（没验到的部分）」。
   CI 不覆盖的路径（如 213 真机行为）要在描述里点名。
6. **CI**：`test.yml`（含 DinD bats）+ `identity.yml` 必须全绿；红了修，不许绕过。
7. **合并**：一律 **`gh pr merge --rebase --delete-branch`**。
   **禁止 `--squash`**——squash 提交单父，`identity-check` 滤不掉，全历史扫描会红
   （2026-11-03 踩过，修复方法见 [会话交接 §4.6](会话交接.md)）。
8. **关卡同步**：合并后勾掉验收清单、更新 [待办](待办.md) 与（如需要）
   [M0 验收记录](M0-验收记录.md)，PR 里 `Closes #N` 让 GitHub 自动关卡。

## 3. 不能碰（完整版在 [会话交接 §3](会话交接.md)）

| 禁止 | 原因 |
|---|---|
| 直推 main | 唯一防线是本地钩子，别拆它 |
| `--squash` 合并 | 弄红 identity-check（§4.6） |
| 改 `tests/images.lock` | digest 单一真源，漂了 `18_public` 红；升级走 `make images-lock` 流程 |
| `.env` / 凭据入库 | 泄露；`.env` 也不许打印进日志 |
| 对 213 宿主栈 `down -v` | 那是生产；销毁性操作必须先问人 |
| 往 `config/` `out/` 写测试数据 | 是宿主共享 bind mount |
| 仓库转公开 | 里面有内网 IP |
| 用 `WF4_ALLOW_PUSH_MAIN=1` / `GIT_IDENTITY_ALLOW=1` 等绕过变量走捷径 | 只留给文档记载的修复流程（如 author 修复） |

## 4. 收尾清单

- [ ] PR 合并方式是 rebase，`identity.yml` 在 main 新 HEAD 上 success
- [ ] Issue 已关（自动或手动），[待办](待办.md) 表已同步
- [ ] 动了运行时（compose / images.lock / 服务配置）→ 提醒把 213 重新
      `USE_GHCR=1 make deploy`，并在 [会话交接](会话交接.md) §0 标注待升级
- [ ] 动了测试 → `test.yml` 的 bats 全绿（本地跑不了 DinD，CI 是唯一验证）
- [ ] 交接文档是否需要刷新（基线 SHA、open PR/Issue 数、新能力、新陷阱）
- [ ] 会话最后输出一份「做了什么 / 没做什么 / 留给谁」的汇报，不要只说「完成了」
