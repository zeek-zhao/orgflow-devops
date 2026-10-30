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
- 路由失败自动回滚由 `render.py` 的「写前比对 + reload 失败不覆盖」保证。
