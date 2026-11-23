# caddy 服务手册

## 1. 职责
反向代理入口：唯一对外入口：`:80 → 308 :443`，按 Host 分站点，Admin API 监听 2019。无证书时生成 bootstrap 自签占位。

## 2. 配置
DOMAIN、CA_DIR、CADDYFILE、CADDY_BIN；站点映射 `/etc/caddy/sites.map`（由 router 覆盖）。

## 3. 启动
make up-caddy（单起，隔离端口）；全栈 make up。容器名 `of-caddy`，镜像按 `tests/images.lock` 的 digest 引用。

## 4. 健康检查
`curl http://127.0.0.1:2019/config/` → 200；Caddyfile 含各 host。

## 5. 用例
tests/bats/S_caddy.bats（健康/Admin/308/分站点/日志）

## 6. 故障排查
502：后端未起；证书报错：确认 ca 卷已由 certs-init 填充。。
