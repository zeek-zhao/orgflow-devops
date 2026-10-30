# 路由注册服务（M0）

职责：集中管理路由（`config/routes.yaml`），渲染 Caddyfile 并通过 Caddy Admin API 热加载。
数据面仍是 Caddy；本服务只做控制面。

## 本地验证

```bash
make render                      # 生成 out/Caddyfile
bash services/router/reload.sh   # 渲染 + POST /load 到 Caddy admin
```

## 新增一个服务路由

1. 在 `config/routes.yaml` 追加：

```yaml
  - path: /myservice
    upstream: myservice:8080
    strip_prefix: true
```

2. `make render`（或等 router 服务 watch 自动热更）。

## 约定

- `strip_prefix: false` → Caddy 用 `handle`（保留前缀）。
- `strip_prefix: true` → Caddy 用 `handle_path`（剥离前缀）。
- `strip` 是 `strip_prefix` 的别名。
- `auth: true` → 在该路由的 `reverse_proxy` 前通过 oauth2-proxy 校验会话，
  401 重定向到 `/auth/oauth2/start?rd={uri}`，并透传用户和邮件请求头。
  默认 `false`，旧路由不受影响；M0 仅 `/jenkins` 开启，其他四条路由公开。
- 路由失败自动回滚由 `render.py` 的「写前比对 + reload 失败不覆盖」保证。

## 热加载与故障处理

- 不设置 `CADDY_ADMIN_URL` / `--admin` 时，单次执行只渲染；内容相同不重写文件。
- 设置 admin 后，先将候选配置 POST 到 `/load`，成功后才原子替换输出文件；
  Caddy 拒绝配置时继续使用旧路由，磁盘上的旧 Caddyfile 也不变。
  Caddy 挂载整个 `out` 目录，以便重启时能读取原子替换后的文件。
  router 同样挂载 `config` 目录，从 `/app/config/routes.yaml` 读取，
  避免编辑器原子保存后单文件 bind mount 仍指向旧文件。
- `reload.sh` 使用 `CADDY_ADMIN_URL`（默认 `http://localhost:2019`），
  无论内容是否变化都会尝试加载；网络超时为 10 秒。连接失败或 HTTP 错误均返回非零，
  stderr 包含目标地址、连接原因或 Caddy 返回的错误正文。
- `--watch` 按 mtime 纳秒值轮询（默认 2 秒，`--interval` 可调整），同时检查大小与 inode。
  仅在处理成功后记录版本；文件暂时缺失、读取失败或 reload 失败会记录错误并在下轮重试，
  不需要再次修改 routes.yaml。内容相同不重复写入或加载；watch 启动时会同步一次。
- 首次启动 watch 且输出不存在时，先生成启动文件供 Caddy 启动，再持续重试 admin；
  这是尚无旧配置时的自举例外，不会覆盖已有文件。
- watch 模式默认在 `0.0.0.0:8090` 提供 `/healthz`（仅容器内部 expose），
  可用 `--health-port` 更改；返回 `{"ok":true,"routes":N}`。
  尚未读取有效路由时返回 503；之后报告最近处理的路由数量，不依赖 Caddy
  admin 可达性，Caddy 自身健康由独立探针检查。其他路径返回 404。
  单次渲染/加载不监听健康端口，原 CLI 行为不变。
  `bash services/router/reload.sh out/Caddyfile --watch --health-port 8090`
  可显式启用长驻加载和健康端点。

回归检查：`python3 -m unittest discover -s services/router -p 'test_*.py'`。
