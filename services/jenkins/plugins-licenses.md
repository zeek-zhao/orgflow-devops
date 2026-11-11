# Jenkins 插件许可证清单

`services/jenkins/plugins.txt` 里 22 个插件的许可证，逐个给依据。**不含「以 MIT 为主」这类概括**
—— 合规评审里含糊的声明等于没写，因为无法被复核。

## 结论

22 个全部为 **MIT**。三个来源，按可靠性排序：

1. 插件仓库根目录的许可证文件（14 个）；
2. 仓库根 `pom.xml` 的 `<licenses>` 段（8 个，这些老插件根目录没有 LICENSE 文件，
   但 POM 是它们发布到 Maven 仓库的元数据，属上游自己的声明）；
3. 单独说明 1 个（`pipeline-graph-view`，见下）。

## 逐条

| # | 插件 | 许可证 | 依据（仓库路径） |
|---|---|---|---|
| 1 | `workflow-aggregator` | MIT | [pom.xml](https://github.com/jenkinsci/workflow-aggregator-plugin/blob/HEAD/pom.xml) `<licenses>` |
| 2 | `git` | MIT | `git-plugin/MIT-LICENSE.txt` |
| 3 | `credentials` | MIT | `credentials-plugin/LICENSE.txt` |
| 4 | `credentials-binding` | MIT | `credentials-binding-plugin/LICENSE` |
| 5 | `plain-credentials` | MIT | [pom.xml](https://github.com/jenkinsci/plain-credentials-plugin/blob/HEAD/pom.xml) `<licenses>` |
| 6 | `ssh-slaves` | MIT | `ssh-slaves-plugin/LICENSE.txt` |
| 7 | `ldap` | MIT | [pom.xml](https://github.com/jenkinsci/ldap-plugin/blob/HEAD/pom.xml) `<licenses>` |
| 8 | `configuration-as-code` | MIT | `configuration-as-code-plugin/LICENSE` |
| 9 | `matrix-auth` | MIT | `matrix-auth-plugin/LICENSE.md` |
| 10 | `matrix-project` | MIT | [pom.xml](https://github.com/jenkinsci/matrix-project-plugin/blob/HEAD/pom.xml) `<licenses>` |
| 11 | `pipeline-graph-view` | MIT | `pipeline-graph-view-plugin/LICENSE.md`（见下） |
| 12 | `pipeline-stage-view` | MIT | `pipeline-stage-view-plugin/LICENSE` |
| 13 | `dark-theme` | MIT | `dark-theme-plugin/LICENSE` |
| 14 | `gerrit-trigger` | MIT | [pom.xml](https://github.com/jenkinsci/gerrit-trigger-plugin/blob/HEAD/pom.xml) `<licenses>` |
| 15 | `tap` | MIT | `tap-plugin/LICENSE.txt` |
| 16 | `ssh-agent` | MIT | [pom.xml](https://github.com/jenkinsci/ssh-agent-plugin/blob/HEAD/pom.xml) `<licenses>` |
| 17 | `docker-plugin` | MIT | [pom.xml](https://github.com/jenkinsci/docker-plugin/blob/HEAD/pom.xml) `<licenses>` |
| 18 | `docker-workflow` | MIT | `docker-workflow-plugin/LICENSE.txt` |
| 19 | `build-monitor-plugin` | MIT | [pom.xml](https://github.com/jenkinsci/build-monitor-plugin/blob/HEAD/pom.xml) `<licenses>` |
| 20 | `throttle-concurrents` | MIT | [LICENSE](https://github.com/jenkinsci/throttle-concurrent-builds-plugin/blob/HEAD/LICENSE) |
| 21 | `timestamper` | MIT | `timestamper-plugin/LICENSE` |
| 22 | `ws-cleanup` | MIT | `ws-cleanup-plugin/LICENSE` |

仓库名按 GitHub 组织 `jenkinsci` 下的 `<插件名>-plugin`，三个例外：

- `throttle-concurrents` → `throttle-concurrent-builds-plugin`（插件 id 与仓库名不一致）；
- `pipeline-graph-view` 与 `dark-theme` 的仓库名与插件 id 相同，无 `-plugin` 后缀问题。

## 两处需要解释的细节

### `pipeline-graph-view` 为什么被 GitHub 判成 `NOASSERTION`

它的 `LICENSE.md` 第一段是：

```text
The MIT License #set( $year = $package.getClass().forName("java.time.LocalDate").now().getYear())
Copyright $year Permission is hereby granted, free of charge, ...
```

`#set( ... )` 是 Apache Velocity 模板语法，用于在构建期把年份替换掉，**残留在了发布文件里**。
GitHub 的许可证检测器看到这段非标准文本就放弃识别，返回 `NOASSERTION`。

所以这是**文本被污染**，不是**许可证不明**。正文与标准 MIT 逐字一致。判定依据是文件里
含 `Permission is hereby granted, free of charge` 全文 —— 这句是 MIT 的识别特征。

### 为什么 8 个只能引 `pom.xml`

`workflow-aggregator`、`plain-credentials`、`ldap`、`matrix-project`、`gerrit-trigger`、
`ssh-agent`、`docker-plugin`、`build-monitor-plugin` 的根目录**没有许可证文件**。
它们通过在 `pom.xml` 里声明 `<licenses>` 来标明许可，这份声明随 artifact 一起发布到
Maven 仓库，是上游对使用者的正式告知。

不能因为「没有 LICENSE 文件」就写「许可证不明」：那会凭空造出一个 copyleft 风险，
是比漏写更严重的错误。

## 复核方法

GitHub 的 `GET /repos/{owner}/{repo}/license` 是**许可证检测**接口，不是「有没有许可证
文件」的接口 —— 文件存在但检测器认不出时它返回 **404**，看起来像「没有许可证」。
本次 9 个插件（含 `pipeline-graph-view`）就是被这个 404 误判的，所以下面给的是
两种口径都查的办法：

```bash
# 1) 检测器认得的（12 个）
curl -s -H "Authorization: Bearer $TOKEN" \
  https://api.github.com/repos/jenkinsci/git-plugin/license | jq -r .license.spdx_id

# 2) 检测器认不得的：列根目录找许可证文件，或读 pom.xml
curl -s -H "Authorization: Bearer $TOKEN" \
  https://api.github.com/repos/jenkinsci/ldap-plugin/contents/pom.xml | jq -r .content \
  | base64 -d | grep -A3 '<licenses>'
```

## 维护

新增插件时，这条要一起改：`scripts/test_plugin_licenses.py` 会检查
`plugins.txt` 的每一项都在本文件里有对应行，缺一项即失败。理由是许可证清单只会在
「加了插件但忘了补清单」这一种情况下出错，而那种情况下没人会主动去看清单。
