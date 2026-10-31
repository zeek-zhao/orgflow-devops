# [34] 会话交接文档：工程现状 + 未解决问题 + 操作陷阱

- **Issue**：#34（需求真本）
- **分支**：`docs/34-session-handoff`
- **依赖**：无（M0 已全部关闭，`df73688` 为基线）
- **token 预算**：约 3 万 token

## 目标

仓库里存在**一份可原样转交的文档** `docs/会话交接.md`。下一个接手方（AI 或人）只读它，就能回答四个问题：

1. 这个工程是什么、架构怎么分层、域名和 IP 怎么规划
2. 现在做到哪了、哪些问题已经解决、解决方式是什么
3. 还差什么、每个未解决项的**根因、复现命令、候选方案**
4. 动手前必须知道的硬约束和环境陷阱

**判断标准**：接手方读完不需要追问、不需要翻 Issue 历史、不会重复踩已知的坑。

## 背景与取证

只列执行方无法自己查到的事实。

| 事实 | 值 / 结论 | 怎么来的 |
|---|---|---|
| 基线 SHA | `df73688` | `git log -1 --format=%h` |
| Issue 总数 | 17，其中 open 只有 #30 | `GET /issues?state=all`（过滤 `pull_request`） |
| 里程碑 | M0 关 5；M1–M4 各 0 | `GET /milestones?state=all` |
| Python 用例 | 81（19+6+18+11+15+12） | `grep -c 'def test_'` 逐文件 |
| bats | 13 文件 / 23 断言 | `ls tests/bats/*.bats`、`grep -h '@test'` |
| CI 在 `df73688` | `提交身份校验` success / `test` success | `GET /commits/df73688/check-runs` |
| `test.yml` 实际跑什么 | identity-check → make test → **DinD bats** | 读 `.github/workflows/test.yml` |
| 213 现状 | SHA `df73688`；10 个 `of-*` 全 healthy | `ssh … 'git rev-parse --short HEAD; docker ps'` |
| 容器名 | 是 `of-oauth2`，**不是** `of-oauth2-proxy` | 同上 `docker ps` |
| 本仓库不用 `DOCKER_UID`/`DOCKER_GID` | `grep -rn` 全仓 0 命中 | 那是 `orgflow` Jenkins 仓库的约定，别带过来 |
| 本仓库不涉及 gerrit | `grep -rin gerrit` 0 命中 | 别把 orgflow 的排查条目抄进来 |
| 主干保护绕过变量 | 是 `WF4_ALLOW_PUSH_MAIN`，**不是** `ORGFLOW_ALLOW_PUSH_MAIN` | 读 `.githooks/pre-push` 第 34 行 |

## 范围

**新增**

| 文件 | 内容 |
|---|---|
| `docs/会话交接.md` | 十节，见 Issue |
| `docs/task-cards/34-session-handoff.md` | 本卡 |

**改**

| 文件 | 改法 |
|---|---|
| `docs/提交规范.md` | 末尾 `## 6. 与其他仓库的关系` → `## 8.`（编号重复，第 7 节之后又出现 6，交叉引用会指错） |

**删**：无。

## 验收

```bash
# 1. 文件存在
test -f docs/会话交接.md && echo ok

# 2. 内部相对链接全部可解析
cd docs && grep -oE '\]\([^)]+\.md\)' 会话交接.md | sed 's/^](//;s/)$//' | while read p; do
  [ -f "$p" ] || echo "MISSING: $p"; done

# 3. 计数与仓库一致
for f in scripts/test_*.py services/router/test_render.py services/auth/test_bootstrap.py; do
  echo "$f $(grep -c 'def test_' $f)"; done   # 期望合计 81
ls tests/bats/*.bats | wc -l                  # 期望 13
grep -h '@test' tests/bats/*.bats | wc -l     # 期望 23

# 4. 固定 IP 表与 compose 一致（10 条，逐条比）
grep -c 'ipv4_address' docker-compose.yml     # 期望 10

# 5. Issue 计数
curl -s -g -H "Authorization: Bearer $(cat ~/.config/wb/github.token)" \
  "https://api.github.com/repos/zeek-zhao/orgflow-devops/issues?state=open" \
  | python -c "import json,sys;print(len(json.load(sys.stdin)))"   # 期望 1
```

**反证**：把文档里的 `81` 改成 `80`，跑第 3 条必须能发现不一致；改回后复绿。

- [ ] 上面 5 条全过
- [ ] 反证做过（贴两次输出）
- [ ] `make identity-check` → `✓ author 唯一`（本机无 make 时用等价 bash）
- [ ] CI `identity` + `test` 双绿

## 禁止事项

- 不得写真实密码 / token：`change-me` 是 `.env.example` 的默认值，可以写；213 上若已换过真值，只写「已换」，不写值
- 不得写猜测：「大概是 X」这种句子会诱导接手方基于错误前提改代码
- 不得把别的仓库（`orgflow` / `orgflow-jenkins`）的约定混进来：本仓不用 `DOCKER_UID`/`DOCKER_GID`、不涉及 gerrit、绕过变量是 `WF4_ALLOW_PUSH_MAIN`
- 不得改 `tests/images.lock`
- 不得自行合并 PR

## 依赖与前置

- [ ] `git log -1 --format=%h` → `df73688`
- [ ] 213 可 SSH（`ssh -i ~/.ssh/id_ed25519 -o IdentitiesOnly=yes jenkins@10.22.67.213 true`）

## 交付物

- [ ] 分支 `docs/34-session-handoff`
- [ ] PR 正文含：做了什么 / 关键决策 / 验收实测表 / 未验证项
- [ ] 验收输出原样贴进 PR

## 交付后的记录

- PR：#
- 结果：
- 与本卡的偏离：
