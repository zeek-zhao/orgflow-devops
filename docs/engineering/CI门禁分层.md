# CI 门禁分层

> 状态：review ｜ 负责人：zeek.zhao ｜ 层级：规程（DOC-P-015）
> 门禁定义真本在 `Makefile`、`scripts/check-fast.sh`、`scripts/check-all.sh`；
> 本文只写**分层理由、各自证明什么、以及红项怎么归因**。
> 提交与分支规则见 [CONTRIBUTING.md](../../CONTRIBUTING.md)。

## 1. 为什么要分层

把重的检查塞进 pre-commit 的结局是每次 `git commit --no-verify` —— 等于没有钩子。
因此按「几秒 / 几分钟」切成两层，再让 CI 做第三层兜底。

| 层 | 入口 | 大概耗时 | 需要 Docker / 网络 | 触发点 |
|---|---|---|---|---|
| 快检查 | `make check` → `scripts/check-fast.sh` | 几秒 | 否 | pre-commit、每次改动 |
| 重检查 | `make check-all` → `scripts/check-all.sh` | 几分钟 | 是 | pre-push |
| CI 必需检查 | Compliance / Test / Identity 三个工作流 | 更长 | 是 | PR 合并前 |

pre-commit 与 `make check` 共用同一份脚本定义，pre-push 与 `make check-all` 共用 ——
**不要在两个地方各维护一份清单**，这是单仓化前后反复出现的坑。

## 2. 快检查七项

| 项 | 脚本 | 证明什么 |
|---|---|---|
| 文档配置 | `scripts/check_docs_meta.py` | 登记册双向一致、ID 与状态见证 |
| 文档索引 | `scripts/test_docs.py` | README 索引、相对链接、服务手册覆盖 |
| 死链 | `scripts/check_export_links.py` | 仓内 0 悬空链接 |
| 脱敏 | `scripts/check-public-redaction.sh` | 公开面无内网标识、凭据形态、内部流程文档 |
| 标签清单 | `scripts/test_labels.py` | 四类标签自洽、模板引用已声明 |
| Action 钉死 | `scripts/check-actions-pinned.py` | 全部 `uses:` 按 40 位 SHA 锁定 |
| 插件许可证 | `scripts/test_plugin_licenses.py` | 22 个插件逐个有许可证与出处 |

复现：`make check`。任一红都会阻断提交。

## 3. 重检查与 CI

`make check-all` = 快检查 + `make test` + `make lint` + `make test-bats`。
`make test` 内含 `test_docs.py`、`test_service_doc_sections.py` 并以 `make docs-check` 收尾；
`make test-bats` 在 DinD 容器里起全套 compose 服务并逐条断言。

显式跳过 bats 用 `SKIP_BATS=1`，但脚本**必须打印「CI 上 Test 工作流仍会跑全部 bats 断言」** ——
静默跳过会让人以为验过了。

CI 三个必需检查红着不合：提交身份、供应链/合规、测试。
门禁反证要求见 [质量管理计划](../project/质量管理计划.md) §3。

## 4. 红项先归因，再动手

| 类别 | 特征 | 改法 |
|---|---|---|
| 真缺陷 | 实现与判据不符 | 改实现，开 BUG-<Issue号> |
| 判据没跟上变化（假红） | 架构改了、断言没改 | **修门禁**，并贴「改坏→红、恢复→绿」反证 |
| 环境差异 | 只在某台机器/某个网络下红 | 写清边界，不改断言 |

三条以上同源失败先停下来写根因，不要逐个打补丁。
#132 的三红就是三种不同根因（占位符误报、假绿、force-push 后 `before` 不可达），
逐个打补丁会把第二种漏掉，见 [问题索引](../project/问题索引.md) §6。

## 5. 禁止事项

- 不写 `|| true`，不放宽断言，不删用例来「修红」
- 不改 `tests/images.lock` 的 digest 来修红
- 不把 WARN 当绿，也不为消 WARN 放宽判据
- 不直接推 `main`，合并用 Rebase 不用 Squash（[AGENTS.md](../../AGENTS.md)）

## 6. 度量命令

```bash
make check
make check-all
make docs-check
make links
make redaction
make test
make test-bats
make identity-check
```

## 7. 边界

| 想知道 | 去哪 |
|---|---|
| 质量目标与反证 | [质量管理计划](../project/质量管理计划.md) |
| 阶段门与实现流程 | [开发生命周期](开发生命周期.md) |
| 配置项与基线 | [配置管理](配置管理.md) |
| 发布前检查 | [版本与发布](版本与发布.md) |
| 验收准出 | [验收与交付准则](../project/验收与交付准则.md) |
