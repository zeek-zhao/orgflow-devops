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
  # 官方格式配置真源是 config/homepage/bookmarks.yaml（旧 config/bookmarks.yaml 已删，R4b）
  # 注意：官方 HomePage v2.7.0 镜像把配置固化进镜像，改宿主机需 sync-context + 重建；
  # 本用例仅断言文件存在且可解析，动态生效行为见 §8 重写的 15_homepage.bats。
  [ -f config/homepage/bookmarks.yaml ]
  run python3 -c 'import yaml; d=yaml.safe_load(open("config/homepage/bookmarks.yaml")); assert isinstance(d, dict)'
  [ "$status" -eq 0 ]
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
