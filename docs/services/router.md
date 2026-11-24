# router 服务手册

> 状态：适用 | 最后核对：2026-11-24 | 对应分支：feat/m0-v2


## 1. 职责
路由注册：读 `routes.yaml` 渲染并调 Caddy admin reload：`/healthz` 200，坏 upstream 422 不 reload，Caddy 不可达 503 降级，相同配置幂等跳过。

## 2. 配置
ROUTES 路径、CADDY_ADMIN（默认 http://caddy:2019）；`config/routes.yaml`（只读挂载）。

## 3. 启动
make up-router（单起，隔离端口 8083）；make routes 触发 reload。容器名 `of-router`，镜像按 `tests/images.lock` 的 digest 引用。

## 4. 健康检查
/healthz 200；改 yaml 后 30s 内新域 200；坏 upstream 422。

## 5. 用例
tests/bats/S_router.bats（健康/热更新/422/幂等）

## 6. 故障排查
reload 503：caddy 不可达；新域不生效：make routes 是否成功。。
