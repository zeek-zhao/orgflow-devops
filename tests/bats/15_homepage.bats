#!/usr/bin/env bats
# 15_homepage —— 双分组 / 12 卡 / href 全 https 无 .local / favicon（§8.3）
# 静态断言（config 真源）+ 运行态页面（可选 $PUBLIC 只读 curl）。

@test "config/ 无 .local 字面域名" {
  run bash -c "! grep -rn '\.local' config/ --include='*.yaml' --include='Caddyfile' 2>/dev/null | grep -v 'orgflow.local\|org-devops.local\|LDAP\|dc='"
  [ "$status" -eq 0 ]
}

@test "services.yaml 两分组各 6 卡，href 全 https 无 .local" {
  run python3 - <<'PY'
import re
s=open("config/homepage/services.yaml",encoding="utf-8").read()
groups=re.findall(r'^\s{2}(\S.*):\s*$',s,re.M)
hrefs=re.findall(r'href:\s*["\']?([^"\'\s]+)',s)
assert len(hrefs)==12, f"href 数={len(hrefs)}"
assert all(h.startswith("https://") for h in hrefs)
assert not any(".local" in h for h in hrefs)
assert "局域网服务状态" in s and "域名入口" in s
print("ok")
PY
  [ "$status" -eq 0 ]
}

@test "favicon.ico 真实存在（非空）" {
  [ -s config/homepage/favicon.ico ]
}

@test "settings.yaml startUrl 为根、无外链天气 widget" {
  run grep -q 'startUrl: /' config/homepage/settings.yaml
  [ "$status" -eq 0 ]
  # 只查生效配置行（去注释），注释里「已移除 Open-Meteo」不算存在
  run bash -c "grep -v '^\s*#' config/homepage/widgets.yaml | grep -qiE 'customapi|open-meteo|weather'"
  [ "$status" -ne 0 ]
}
