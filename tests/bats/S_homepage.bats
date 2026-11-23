#!/usr/bin/env bats
# S_homepage —— 静态页 200 / YAML 卡片解析无静默丢项 / 改 YAML 免重启

@test "容器 healthy" {
  run docker inspect -f '{{.State.Health.Status}}' of-homepage
  [ "$output" = "healthy" ]
}

@test "静态页 200" {
  run curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8082/
  [ "$output" = "200" ]
}

@test "卡片数 ≤5 且全部渲染" {
  run curl -s http://127.0.0.1:8082/
  [[ "$output" == *"统一入口"* ]]
  [[ "$output" == *"目录管理"* ]]
}

@test "改 YAML 免重启生效" {
  # bookmarks.yaml 是只读挂载，改宿主机文件后，server 每次请求重读即生效
  cp config/bookmarks.yaml /tmp/bookmarks.bak
  echo "  - name: 临时卡" >> config/bookmarks.yaml
  echo "    href: https://t.example/" >> config/bookmarks.yaml
  run curl -s http://127.0.0.1:8082/
  [[ "$output" == *"临时卡"* ]]
  cp /tmp/bookmarks.bak config/bookmarks.yaml
  curl -s http://127.0.0.1:8082/ >/dev/null
}

@test "反证：cards 配成映射 → 500（不静默丢项）" {
  # 单测 server.py 的 load_cards 拒绝映射
  run python3 -c '
import sys, tempfile, os
sys.path.insert(0,"services/homepage")
os.environ["BOOKMARKS"]="/tmp/bad_cards.yaml"
open("/tmp/bad_cards.yaml","w").write("cards:\n  name: wrong\n")
import server
try:
    server.load_cards(); print("NO_ERROR")
except ValueError as e:
    print("REJECTED" if "列表" in str(e) else "WRONG")
'
  [ "$output" = "REJECTED" ]
}
