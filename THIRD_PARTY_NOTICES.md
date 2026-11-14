# Third-Party Notices / 第三方组件声明

本项目自身代码以 [Apache-2.0](LICENSE) 发布。下列第三方组件随容器镜像一并分发
（GHCR 上的包**匿名可拉取**，即分发已经发生），各自保留其原始许可证。
本文件与 [`licenses/`](licenses/) 目录共同构成许可证义务要求的「随附许可证副本」：

| 条款 | 要求 | 本项目对应做法 |
|---|---|---|
| GPL-2.0 §1 | 分发目标码时随附许可证副本 | [`licenses/GPL-2.0.txt`](licenses/GPL-2.0.txt) |
| GPL-3.0 §4/§6 | 随附许可证 + 提供 Corresponding Source 获取方式 | [`licenses/GPL-3.0.txt`](licenses/GPL-3.0.txt) + 本文 §4 |
| EPL-1.0 §3 | 声明源码可得性 | 本文 §4.3 |
| Apache-2.0 §4 | 保留版权与 NOTICE | [`licenses/Apache-2.0.txt`](licenses/Apache-2.0.txt) |
| MIT | 保留版权声明与许可声明 | [`licenses/MIT.txt`](licenses/MIT.txt) |

> 机器可读版本：`make sbom` 生成的 SPDX 2.3 文档（输出到 `out/sbom.spdx.json`，
> 不随仓库提交，随 release 附上）。本文件是人工核对的许可证依据，SBOM 是机器可读的
> 组件清单，两者需同步更新。

## 1. 上游组件（原样镜像，未修改）

| 组件 | 发布引用（GHCR） | 上游 | 许可证 | 随附许可证全文 |
|---|---|---|---|---|
| Caddy 2 | `mirror-caddy:2` | [caddyserver/caddy](https://github.com/caddyserver/caddy) | Apache-2.0 | Apache-2.0.txt |
| OpenLDAP 2.x | `mirror-openldap:1.5.0` | [osixia/docker-openldap](https://github.com/osixia/docker-openldap) | 封装脚本 MIT；目录服务本体 **OpenLDAP Public License 2.8** | MIT.txt + OpenLDAP-2.8.txt |
| phpLDAPadmin | `mirror-phpldapadmin:0.9.0` | [osixia/docker-phpldapadmin](https://github.com/osixia/docker-phpldapadmin) | 封装脚本 MIT；应用本体 **GPL-2.0** | MIT.txt + GPL-2.0.txt |
| Dex | `mirror-dex:v2.41.1` | [dexidp/dex](https://github.com/dexidp/dex) | Apache-2.0 | Apache-2.0.txt |
| OAuth2 Proxy | `mirror-oauth2-proxy:v7.6.0` | [oauth2-proxy/oauth2-proxy](https://github.com/oauth2-proxy/oauth2-proxy) | MIT | MIT.txt |
| Nexus Repository 3 | `mirror-nexus:3.92.2` | [sonatype/nexus-public](https://github.com/sonatype/nexus-public) | **EPL-1.0** | EPL-1.0.txt |
| Homepage | `mirror-homepage:v2.7.0` | [gethomepage/homepage](https://github.com/gethomepage/homepage) | **GPL-3.0** | GPL-3.0.txt |

各镜像的精确版本由 digest 锁定，见 [`docker-compose.ghcr.yml`](docker-compose.ghcr.yml)
与 [`scripts/nexus-deploy.sh`](scripts/nexus-deploy.sh)；汇总见 SBOM。

## 2. 本项目构建的镜像

| 镜像 | 基础镜像 | 引入的 copyleft | 声明许可证 |
|---|---|---|---|
| `jenkins:24.04-v3` | `jenkins/jenkins:lts-jdk21`（MIT） | 无（核心与所用插件均为 MIT 类） | MIT |
| `jenkins-agent:24.04-v1` | `jenkins/ssh-agent:jdk21`（MIT） | 无（仅 Docker CLI，Apache-2.0） | MIT |
| `router:24.04-v1` | `ubuntu:24.04` | 无（本项目代码 Apache-2.0；Python 为 PSF-2.0） | Apache-2.0 |
| `jjb:24.04-v1` | `ubuntu:24.04` | 无（jenkins-job-builder 6.5.0，Apache-2.0） | Apache-2.0 |
| `dnsmasq:24.04-v1` | `ubuntu:24.04` + apt `dnsmasq` | **GPL-2.0**（apt 安装，未修改） | GPL-2.0 |
| `m0-test:24.04-v1` | `ubuntu:24.04` | 无 | Apache-2.0 |

Ubuntu 基础镜像本身包含大量组件（GPL/LGPL/BSD 等），其版权与许可证汇总保存在镜像内
`/usr/share/doc/*/copyright`，随镜像原样分发。

## 3. 运行时依赖（非分发，仅调用）

| 依赖 | 许可证 | 说明 |
|---|---|---|
| Jenkins 插件（22 个） | 全部 MIT | 插件随 `jenkins` 镜像分发。逐个的许可证与依据（仓库路径或 `pom.xml` 的 `<licenses>` 段）见
[`services/jenkins/plugins-licenses.md`](services/jenkins/plugins-licenses.md)；Jenkins 官方 update-center **不提供 license 字段**，所以依据只能来自插件仓库本身 |
| Docker Engine / Compose | Apache-2.0 | 宿主提供，不随本项目分发 |
| Python 标准库 | PSF-2.0 | 本项目 Python 代码**零第三方 PyPI 依赖** |

插件清单的机器可读来源：`services/jenkins/plugins.txt`。其中
`pipeline-graph-view` 上游 LICENSE 文件非标准文本（GitHub 判定 `NOASSERTION`），
按上游仓库声明为准。

## 4. 源码获取（Corresponding Source）

### 4.1 未修改的上游组件

本项目**未修改**上述任何 copyleft 组件的源码，只做原样镜像与配置。
Corresponding Source 即上游对应版本的源码：

- GPL-3.0 组件（Homepage）：`https://github.com/gethomepage/homepage`，版本 `v2.7.0`
- GPL-2.0 组件（phpLDAPadmin）：`https://github.com/leenooks/phpLDAPadmin` 对应版本；
  镜像封装为 `osixia/docker-phpldapadmin:0.9.0`
- GPL-2.0 组件（dnsmasq）：Ubuntu 24.04 归档中的 `dnsmasq` 源码包，与镜像内二进制同版本
- OpenLDAP Public License 2.8 组件：`https://github.com/openldap/openldap`，对应 2.x 版本
- EPL-1.0 组件（Nexus）：`https://github.com/sonatype/nexus-public`，版本 `3.92.2`

### 4.2 本项目构建的镜像

`jenkins` / `jenkins-agent` / `router` / `jjb` / `dnsmasq` / `m0-test` 的构建源码
即本仓库内的 `Dockerfile` 与 `services/`、`tools/` 目录，随仓库公开。

### 4.3 EPL-1.0 源码可得性声明

Nexus Repository 以 EPL-1.0 分发。其源码可从上游仓库（§4.1）获取，
本项目未修改其源码，仅以容器镜像形式再分发。

### 4.4 其他获取方式

若上述渠道不可用，请在本仓库开 issue，我们提供等价的分发方式。

## 5. 已知不一致（照实记录，不掩盖）

1. **`sonatype/nexus3` 镜像 label 写的是 `Apache-2.0`，实际是 EPL-1.0。**
   上游 `nexus-public/LICENSE.txt` 首行是 `Eclipse Public License - v 1.0`。
   以本文 §1 为准，不要依据镜像 label 做合规判断。
   **未向上游反馈**：反馈要以维护者个人身份在 `sonatype` 的仓库公开发言，属于对外承诺，
   需仓库所有者决定口径；在此之前本项目自行更正即可（不从镜像 label 取许可证）。
   复活条件：决定反馈时，或该镜像出现在本项目之外的消费链路里。
2. **`osixia/phpldapadmin:0.9.0` 镜像内未随附 GPL-2.0 全文**（实测容器内无
   `COPYING`/`LICENSE`）。本项目在 `licenses/GPL-2.0.txt` 补齐该义务。
3. **`oauth2-proxy` 的 `LICENSE` 文件只有 MIT 正文、无版权行**，其版权主体以其仓库
   声明为准；本项目按 MIT 处理并保留全文。
4. **`gethomepage/homepage` 镜像内 `/usr/local/LICENSE` 是 Node.js 的许可**，不是
   GPL-3.0。本项目在 `licenses/GPL-3.0.txt` 补齐。

## 6. 商标

Jenkins®（Jenkins 项目）、Caddy®（Stack Holdings）、Nexus Repository®（Sonatype）、
Docker®（Docker Inc.）、Ubuntu®（Canonical Ltd.）等为各自权利人商标。
本项目仅在指称意义上使用这些名称，不表示任何形式的背书、赞助或关联。
