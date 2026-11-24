# caddy 服务手册

## 1. 职责
反向代理入口：唯一对外入口。内网 `:80 → 308 :443` 按 Host 分站点；公网入口 `:PUBLIC_PORT`（默认 18081，纯 HTTP，TLS 由 Tailscale Funnel 边缘终止）按 path 反代，HomePage 占根路径 `/`。Admin API 只绑内网 IP `192.168.90.10:2019`，公网不可达，无 `/caddy/*` 路由。无证书时生成 bootstrap 自签占位。

## 2. 配置
DOMAIN、CA_DIR、CADDYFILE、CADDY_BIN、PUBLIC_PORT、PUBLIC_HOST；公网入口站点块真源 `config/Caddyfile`，router `/render` 可热更新实跑配置。

## 3. 启动
make up-caddy（单起，隔离端口）；全栈 make up。容器名 `of-caddy`，镜像按 `tests/images.lock` 的 digest 引用。

## 4. 健康检查
公网入口 `curl -H 'Host: <PUBLIC_HOST>' http://127.0.0.1:18081/healthz` → 200；Admin API 走内网 `curl http://192.168.90.10:2019/config/` → 200（127.0.0.1:2019 不再监听）；Caddyfile 含各 host。

## 5. 用例
tests/bats/S_caddy.bats（健康/Admin/308/分站点/日志）

## 6. 故障排查
502：后端未起；证书报错：确认 ca 卷已由 certs-init 填充。。
