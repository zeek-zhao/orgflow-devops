<!--
  M0 PR 模板（方案书 §6 / REQ-MIN-12）
  首行必须是 Closes #<issue>：合并即自动关单，不允许手工关 Issue。
  三条必需检查（Compliance / Test / Identity）全绿才可合；合并一律 Rebase，禁止 Squash。
-->

Closes #<issue 号，例如 169>

## 为什么改

<!-- 一句话说清这条 PR 解决什么问题。对应哪张 Issue、哪个验收标准。 -->

## 代价

<!-- 引入了什么新依赖 / 新配置项 / 需要人工做的事。没有就写「无」。 -->

## 怎么验证

<!-- 贴可照抄的命令 + 输出摘要；至少一条反证（删/改某处 → 必须红，恢复后复绿）。 -->

```bash
# 命令
```

输出摘要：

```
# 关键输出
```

## 检查清单

- [ ] 首行 `Closes #<issue>` 已填，且本 PR 只关这一张 Issue
- [ ] 单一功能，改动 ≤ 15 个文件（超了拆 PR）
- [ ] `make record` 生成的本条记录已提交进分支（REQ-MIN-13）
- [ ] Compliance / Test / Identity 三条检查全绿
- [ ] 合并方式为 Rebase（禁止 Squash，会产生 noreply 作者）
