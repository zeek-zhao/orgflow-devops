# Jenkins 插件版本锁定（M1）

`services/jenkins/plugins.txt` 每行 `name:version` 为**钉死版本**，`jenkins-plugin-cli` 按此安装。
本文件记录 core 基线、每个插件版本、update center 获取时间，供审计与复现。禁止浮动 tag / 裸插件名。

## 来源与方法

- **core / 基底**：`jenkins/jenkins:lts-jdk21@sha256:74401de6a6f92e1afe1b02d1c8e3d0c33f263bfb5275dd8813f9150355f2367b`（与 `main` 同一 digest）。该镜像对应 **Jenkins core 2.580.2 / Java 21**（依据：main 分支 `docs/services/jenkins.md` 于 2026-11-06 抓取的 `/systemInfo` 实测值）。
- **插件版本**：解析官方 update center `https://updates.jenkins.io/update-center.json`（`updateCenter.post({...})` JSONP）里每个插件的 `version` 字段。
- **获取时间**：2026-11-25（UTC+8，M1 施工时点）。
- **兼容口径**：以上插件的 `buildDate` 均 ≤ 2026-11-17（见下表），与 core 2.580.2（2026-11-06 LTS）同期；`jenkins-plugin-cli` 仅按 `name:version` 精确下载，不解析依赖最新版本。若后续 core 升级，须重新取版本并回填本表。

## 版本表

| 插件 | 版本 | buildDate（update center） | 用途 |
|---|---|---|---|
| workflow-aggregator | 608.v67378e9d3db_1 | 2025-03-19 | pipeline 全家桶（workflow-cps / job 解析） |
| git | 5.11.0 | 2026-10-11 | Job DSL 的 `cpsScm` 拉仓库 |
| credentials | 1514.vb_01eb_014e7d4 | 2026-10-13 | JCasC 凭据框架 |
| credentials-binding | 728.v902a_273b_8947 | 2026-07-09 | pipeline `withCredentials` |
| plain-credentials | 199.v9f8e1f741799 | 2025-06-27 | Secret text 凭据 |
| ssh-slaves | 3.1097.v868116049892 | 2026-02-13 | SSH 接入 agent 节点 |
| ssh-credentials | 372.va_250881b_08cd | 2026-04-06 | `basicSSHUserPrivateKey`（随 ssh-slaves，显式钉死） |
| ldap | 825.v2fca_37dd5b_cb_ | 2026-08-25 | LDAP 登录与组解析 |
| configuration-as-code | 2147.v8a_8d38668c72 | 2026-11-05 | JCasC（`jenkins.yaml` 生效） |
| matrix-auth | 3.3 | 2026-07-14 | `authorizationStrategy.projectMatrix` |
| job-dsl | 3752.vb_199526b_20c3 | 2026-11-17 | JCasC `jobs: - file:` 生成 9 条 Job |
| timestamper | 1.30 | 2025-07-02 | 构建日志时间戳（验收看并发重叠） |
| ws-cleanup | 0.49 | 2025-08-11 | 构建后清理 workspace |
| theme-manager | 368.v587224fde1f6 | 2026-11-10 | 全局主题管理（core≥2.555.3，线上 2.580.2 满足） |
| dark-theme | 652.vea_da_dfea_e769 | 2026-03-23 | 默认深色主题（core≥2.528.3） |

> 主题插件版本于 2026-11-25 从 `https://updates.jenkins.io/update-center.json` 实测解析（非手写）：
> `theme-manager 368.v587224fde1f6`、`dark-theme 652.vea_da_dfea_e769`。
> 生效顺序：先重建镜像（插件进镜像）→ 再应用 JCasC `appearance`，否则缺插件会导致 JCasC `No such theme` 启动失败。

## 复现步骤

```bash
curl -sSL https://updates.jenkins.io/update-center.json -o /tmp/uc.json
python3 - <<'PY'
import json, re
s=open('/tmp/uc.json',encoding='utf-8').read()
m=re.search(r'updateCenter\.post\((.*)\)\s*;?\s*$', s, re.S)
d=json.loads(m.group(1)) if m else json.loads(s)
for name in open('services/jenkins/plugins.txt').read().split():
    n=name.split(':')[0]
    print(n, d['plugins'][n]['version'])
PY
```
