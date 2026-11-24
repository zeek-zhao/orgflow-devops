Closes #<issue 号>

## 任务号
<!-- 如 m0-v3-t9 / m0-v2-t4；一个 PR 仅一个任务 -->

## 改动范围
<!-- 这条 PR 解决什么；列出关键文件，≤15 文件 -->

## 为什么改
<!-- 对应 Issue 的哪个验收标准 / 根因 -->

## 是否动线上
<!-- 是/否；若是，写清零停机步骤（recreate 单容器 / caddy reload），禁止 down 整栈/删网络卷/prune -->

## 怎么验证
<!-- 可照抄的命令 + 真实输出（状态码 / imageId / 接口 JSON），至少一条反证 -->

```bash
```

## 回滚命令
<!-- 具体可执行：git revert <sha> + 涉及的 caddy reload / 旧 compose 重建 -->

## 检查清单
- [ ] 首行 `Closes #<issue>` 已填，仅关一张 Issue
- [ ] 任务号已填；单一功能，改动 ≤ 15 文件
- [ ] 是否动线上已声明；若动线上，零停机步骤与回滚命令齐全
- [ ] 验收命令与真实输出已贴（不接受"已完成"）
- [ ] `make check` 绿；三条必需检查（Compliance / Test / Identity）全绿
