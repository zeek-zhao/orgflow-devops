# ADR-03：双层 digest（上游 + 本分支产物）

| 项 | 值 |
|---|---|
| 状态 | 已接受 |
| 日期 | 2026-11-24 |
| 起因 | v1.0 §4 要求镜像照抄 main 来源但全部在本分支重建、钉本分支新 digest |
| 影响面 | 7 Dockerfile、CI、tests/images.lock、check-* 门禁、镜像与供应链.md |

## 背景

需要在「不重复造轮子（照抄 main 已验证的上游镜像）」与「本分支可独立构建、不依赖 main 产物」之间取舍。单一层 digest 要么绑死 main（无法独立），要么混入未经验证的上游（供应链风险）。

## 决策

采用双层 digest：
- **上游层**：每个 Dockerfile 的 FROM 用官方/基底镜像 @sha256（照抄 main 登记表），真源 `docs/engineering/镜像与供应链.md`，由 `check-upstream-digest.sh` 校验。
- **产物层**：本分支 CI（build-images.yml）构建推 GHCR 的 `m0-*` 镜像 digest，记录 `tests/images.lock`，由 `make images-lock` 回填，人不手改。
- 薄封装层叠加配置（Caddyfile/LDIF/homepage yaml），自建层（dnsmasq/router）FROM ubuntu:24.04@fe815609。

## 放弃的方案

| 方案 | 不选的理由 | 什么条件下值得重提 |
|---|---|---|
| 直接引用 main 产物（旧口径） | 不满足 AC-20「删其他分支仍可独立构建」 | 从不 |
| 全部从 ubuntu 自建 | 官方镜像已有维护，重复且易缺依赖 | 无官方镜像时（dnsmasq/router 已是） |
| 只锁 tag 不锁 digest | tag 可漂移，供应链不可控 | 从不 |

## 后果

- **变好的**：来源可追溯、本分支自包含、上游升级单点可控（登记表+门禁）。
- **变差的**：两个 digest 层要同步维护；CI 首次构建需回填产物 digest。
- **需要跟着改的**：base-image/upstream/image-source 三个门禁、sync-build-context.sh、镜像与供应链.md。

## 验证方式

`bash scripts/check-upstream-digest.sh` 输出 6 个 Dockerfile FROM 与登记表一致；`make check-all` 全绿；新克隆仅 checkout 本分支 `bash scripts/sync-build-context.sh && docker compose build` 成功（AC-20）。
