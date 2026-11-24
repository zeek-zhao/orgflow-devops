# certs-init 服务手册

> 状态：适用 | 最后核对：2026-11-24 | 对应分支：feat/m0-v2


## 1. 职责
内部 CA 签发：首次生成自签 CA（10年）+ 站点证书（825天，SAN 含 `*.<DOMAIN>`）到共享卷；二次幂等跳过；`FORCE=1` 重签。

## 2. 配置
DOMAIN、SITES（子域清单）、CA_DIR（默认 /ca）、FORCE。

## 3. 启动
make up（作为编排第 2 步）；make ca-rotate 强制重签。容器名 `of-certs-init`，镜像按 `tests/images.lock` 的 digest 引用。

## 4. 健康检查
容器 exit 0；卷内有 ca.crt + site.crt。

## 5. 用例
tests/bats/S_certs-init.bats（exit0/卷内证书/SAN 通配/二次幂等）

## 6. 故障排查
证书过期或不匹配：make ca-rotate；二次未跳过：检查 CA 有效期。。
