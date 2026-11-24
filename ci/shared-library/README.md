# ci/shared-library —— 挂载即共享库（M1）

本目录**不做 Git SCM 拉取、不配 `@Library` / Global Shared Library**。Jenkins 的 Global Shared Library 只支持 Modern/Legacy SCM retriever，没有"本地目录"类型；用 git 拉同一仓库既慢又与"改了立即可见"冲突。

## 机制

- `services/jenkins-agent/compose.yml` 把宿主 `ci/shared-library` 挂到容器内 **`/opt/orgflow/shared:ro`**；
- Job（Jenkinsfile）用 `sh /opt/orgflow/shared/bin/check-lan.sh <svc>` 直接调用；
- 宿主改完脚本，**下一次构建立即生效**——不重建容器、不重新拉库；
- 挂载是只读，Job 不得往 `/opt/orgflow/shared` 写文件；权限 755/644（`scripts/gen-jenkins-secrets.sh` 会 `chmod -R a+rX`），保证普通用户 jenkins 可读不可写。

## 文件

| 路径 | 作用 |
|---|---|
| `bin/check-lan.sh` | 单服务探测（唯一真源）：dns/ldap/caddy/homepage/ldapadmin/router/jenkins/jenkins-agent |
| `bin/check-lan-all.sh` | 并行跑全部服务，输出 Markdown 表 `lan-report.md` |
| `lib/ServiceMatrix.groovy` | 服务清单与探测类型（可选；`load` 失败时退回纯 shell，不依赖它） |

## 可验证性（验收项）

1. 宿主改 `bin/check-lan.sh` 加一行 echo → 不重建容器、直接重跑 Job → console 立刻出现新输出；
2. `docker exec of-jenkins-agent ls /opt/orgflow/shared/bin` 能看到同一份文件。
