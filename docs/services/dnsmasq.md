# dnsmasq 服务手册

> 状态：适用 | 最后核对：2026-11-24 | 对应分支：feat/m0-v2


## 1. 职责
DNS 解析：把 `*.DOMAIN` 通配解析到 Caddy 固定 IP `.10`，未定义子域同样落 `.10`，其余 NXDOMAIN。

## 2. 配置
DOMAIN（域名）、IP_CADDY（Caddy IP）、NET_SUBNET。由 entrypoint 渲染 `/etc/dnsmasq.d/orgflow.conf`。

## 3. 启动
make up-dnsmasq（单起，隔离端口 5353，不占宿主 53）。容器名 `of-dnsmasq`，镜像按 `tests/images.lock` 的 digest 引用。

## 4. 健康检查
pgrep dnsmasq；`dig @127.0.0.1 -p 5353 home.<DOMAIN> +short` → .10。

**面板探测（T9）**：HomePage 的 DNS 卡用 ICMP ping **固定 IP `192.168.90.15`**（非容器名 `dnsmasq`）——HomePage 容器内解析不到 `dnsmasq` 容器名会红卡；固定 IP 与其余服务地址口径一致，不依赖容器名解析。真实 DNS 功能校验仍用 `dig @192.168.90.15`。

## 5. 用例
tests/bats/S_dnsmasq.bats（健康/dig/通配/NXDOMAIN/日志）

## 6. 故障排查
解析不对：确认 IP_CADDY 与 DOMAIN；容器起不来：查 entrypoint 生成的 conf。。
