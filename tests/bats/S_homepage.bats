#!/usr/bin/env bats
# S_homepage —— 容器健康 / 静态页 200 / 双分组卡片 / manifest 渲染一致（R6 后）
# 变量：PFX 容器前缀、P_HOMEPAGE 宿主端口。

@test "容器 healthy" {
  run docker inspect -f '{{.State.Health.Status}}' "${PFX:-of}-homepage"
  [ "$output" = "healthy" ]
}

@test "静态页 200" {
  run curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${P_HOMEPAGE:-8082}/"
  [ "$output" = "200" ]
}

@test "两分组名都在页面上" {
  run curl -s "http://127.0.0.1:${P_HOMEPAGE:-8082}/"
  [[ "$output" == *"服务状态"* ]]
  [[ "$output" == *"公网入口"* ]]
}

@test "manifest 渲染一致（6+4 卡、href 全 https 无 .local）" {
  run python3 - <<'PY'
import re,sys
s=open("config/homepage/services.yaml",encoding="utf-8").read()
hrefs=re.findall(r'href:\s*["\']?([^"\'\s]+)',s)
assert len(hrefs)==10, f"卡片数={len(hrefs)}"
assert all(h.startswith("https://") for h in hrefs), "存在非 https href"
assert not any(".local" in h for h in hrefs), "存在 .local href"
assert "服务状态" in s and "公网入口" in s
assert not re.search(r'\[(?:lan|domain|LAN|DOMAIN|NO-UI)\]',s), "存在 R6 前的方括号前缀"
PY
  [ "$status" -eq 0 ]
}
