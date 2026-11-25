# <SVC> 服务（脚手架模板生成的骨架）

> 本目录由 `scripts/new-service.sh <SVC>` 从 `services/_template/` 生成。
> 生成后必须完成下列 5 步手工操作，否则镜像门禁（`--mode=lock`）与文档门禁会红。

## 生成后的 5 步手工清单
1. **manifest 加行**：`services/manifest.tsv` 按 order/depends_on 加一行（up.sh 只读 order/service/depends_on）。
2. **defaults.env 加段**：`config/defaults.env` 加 `IP_<SVC>`（固定 IP）与 `P_<SVC>_HTTP`（容器内监听口，第③层）；对外口用 `PUB_HTTP_<SVC>`（第②层），不得写死字面端口。
3. **compose 加 image 变量**：`config/images.env` 加 `IMAGE_<SVC>` 与 `UPSTREAM_<SVC>`（FROM digest）；compose 里 image 用 `${IMAGE_<SVC>:-<GHCR digest>}`。
4. **images.lock 加行**：`tests/images.lock` 加 `<SVC>` 行（自建服务用 HASHED，内容哈希 tag；官方镜像行填 digest）。
5. **docs 加篇**：`docs/services/<svc>.md` 新建服务手册并在 `docs/README.md` 登记（check-docs.sh 双向一致）。

## 端口与 IP 约定（M2 §1 三层模型）
- ① Funnel 边缘口：`FUNNEL_PORT_*`，仅 443/8443/10000，公网可见。
- ② 宿主回环口：`PUB_HTTP_<SVC>`，Funnel 回源目标，任意空闲口。
- ③ 容器内监听口：`P_<SVC>_HTTP`，服务自身端口，仅供反代与调试。

## 自检
- `make render && make check` 全绿（端口配置/服务清单/镜像锁/文档门禁均通过）。
