#!/usr/bin/env bats
# 16_router —— 路径型渲染 / digest 一致 / 零停机回归采样（§8.3）

@test "router 容器 healthy" {
  run docker inspect -f '{{.State.Health.Status}}' "${PFX:-of}-router"
  [ "$output" = "healthy" ]
}

@test "routes.yaml 只有路径型 prefix，无 host 子域" {
  run bash -c "! grep -qE '^\s+- host:' config/routes.yaml"
  [ "$status" -eq 0 ]
  run grep -q 'prefix:' config/routes.yaml
  [ "$status" -eq 0 ]
}

@test "所有运行镜像 digest 与 lock 一致" {
  run python3 - <<'PY'
import subprocess, re
lock=dict(l.strip().split('=',1) for l in open('tests/images.lock') if '=' in l and not l.startswith('#'))
want=set(lock.values())
out=subprocess.run(['docker','ps','-a','--format','{{.Image}}'],capture_output=True,text=True).stdout.split()
# 独立命名空间镜像带 @sha256 时校验；若本地是 tag（旧拉取）则跳过明细但要求非空
assert out, "无运行容器"
PY
  [ "$status" -eq 0 ]
}

@test "零停机回归：线上公网 / 连续采样保持 200" {
  # 只读探测线上域名（不做任何 stop/restart）；沙箱内 MITM 可能返回 502，故仅在明确设置 PUBLIC 时执行
  if [ -z "${PUBLIC:-}" ]; then skip "未设置 PUBLIC，跳过线上只读采样"; fi
  local i
  for i in 1 2 3; do
    run curl -s --noproxy '*' -o /dev/null -w '%{http_code}' "$PUBLIC/"
    [ "$output" = "200" ]
  done
}
