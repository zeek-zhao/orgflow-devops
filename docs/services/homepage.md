# homepage 服务手册

## 1. 职责
统一面板：`home.<DOMAIN>` 静态面板：读 bookmarks.yaml 渲染 ≤5 张卡片，每次请求重读（改 YAML 免重启），解析失败显式报错不静默丢项。

## 2. 配置
BOOKMARKS 路径；`config/bookmarks.yaml`（只读挂载）。

## 3. 启动
make up-homepage（单起，隔离端口 8082）。容器名 `of-homepage`，镜像按 `tests/images.lock` 的 digest 引用。

## 4. 健康检查
页面 200；卡片全部渲染；cards 配成映射 → 500。

## 5. 用例
tests/bats/S_homepage.bats（200/卡片/免重启/反证）

## 6. 故障排查
卡片不显示：检查 bookmarks.yaml 的 cards 是否为列表。。
