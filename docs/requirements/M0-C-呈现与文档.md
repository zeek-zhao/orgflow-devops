# M0-C · 呈现与文档（REQ-M0-C*）

> 需求基线 · DOC-R-007 ｜ 状态：approved ｜ 负责人：zeek.zhao ｜ 评审日期：2026-11-11 ｜ 复审：12 个月
> 本域 2 条，覆盖 Issue #94 #95（全部已关闭）。
> 规则见 [需求基线入口](README.md)：**要求与判据冻结，现状与证据可变**。

## 1. 需求表

| 编号 | 要求 | 验收判据 | 现状 | 证据 |
|---|---|---|---|---|
| **REQ-M0-C1** | 首页一屏可见每个服务的存活状态、时间、天气；每张服务卡带文档直链；**不注入任何需要 token 或 API key 的 widget**（首页是公开的） | `python3 scripts/test_homepage_config.py` → 退出码 0；`bats tests/bats/21_homepage.bats` 绿；反证：把 `bookmarks.yaml` 的值改回映射形式 → `/api/bookmarks` 缺 `href`，用例必须红 | 已实现 | [#94](https://github.com/zeek-zhao/orgflow-devops/issues/94) |
| **REQ-M0-C2** | `docs/` 通过 Caddy 静态路由对外可访问，且是**唯一**走网关鉴权的路由；每份服务文档统一补齐「使用指南 / 注意事项 / 设置 / 备份」四段，首页链接直达 | `python3 scripts/test_service_doc_sections.py` → 退出码 0（缺任一段即红）；`python3 scripts/gen_docs_site.py` 能完整产出；反证：删掉某份服务文档的一段 → 覆盖自检必须红 | 已实现 | [#95](https://github.com/zeek-zhao/orgflow-devops/issues/95) |

## 2. 要点与坑

### C1 的那条「不注入需凭据的 widget」是硬约束，不是偏好

首页 `home.<domain>` 不经过任何认证。任何需要 token 的 widget 放上去，等于把凭据暴露给所有能访问内网的人。所以天气走 Open-Meteo 的免 key 端点，活性检测走 `siteMonitor` 的匿名 HTTP 探测。

**判据把这条落成机械检查**：`test_homepage_config.py` 会拦需要 `apikey` 的配置。

### C1 踩过的坑：bookmark 的值必须是列表（#42）

`bookmarks.yaml` 把书签值写成映射时，解析器**静默丢掉** `href` 与 `icon`，前端 `new URL(e.href)` 拿到 `undefined` 直接抛 `TypeError: Failed to construct URL`，整页白屏。

最难查的地方是：`curl` 返回 200、HTML 里 href 都在，**只有真浏览器会炸**。所以修法不是改 YAML 就完事，而是加一条不依赖页面状态码的断言 —— `GET /api/bookmarks` 每个书签必须同时有 `name` 和 `href`。

这条经验直接改写了 C1 的判据：**状态码 200 不能证明页面能用**。

### C2：四段覆盖自检为什么进 `make test`

11 份服务文档原本各写各的，缺段没人发现。`test_service_doc_sections.py` 用 `REQUIRED = (使用指南, 注意事项, 设置, 备份)` 逐份检查，缺一段即红。

它还有第二条断言（保持六节），防止有人为了过检把四段合并成两段蒙过去。**判据能被绕过，就等于没有判据**，所以这里必须同时锁下限和结构。

## 3. 与文档体系的关系

C2 只要求「四段齐全、能对外访问」。**它不管**文档元数据（DOC-ID、状态、评审日期）——那是 `docs/文档规范.md` 与 `scripts/check_docs_meta.py` 的范围。

两者会同时作用于 `docs/services/*.md`：C2 查内容结构，`docs-check` 查配置项登记。改一份服务手册要同时过这两关。
