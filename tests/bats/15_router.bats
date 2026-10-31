#!/usr/bin/env bats
setup() {
    load 'helpers/common'
    setup_gw
}

@test "router: health, idempotent output and rejected invalid input" {
    run compose_exec router python3 -c "import urllib.request;print(urllib.request.urlopen('http://127.0.0.1:8090/healthz',timeout=5).status)"
    [ "$status" -eq 0 ]
    [ "$output" = 200 ]
    run compose_exec router python3 -c '
import hashlib, subprocess, tempfile
from pathlib import Path
live = Path("/app/out/Caddyfile")
before = live.read_bytes()
mtime = live.stat().st_mtime_ns
with tempfile.TemporaryDirectory() as directory:
    out = Path(directory) / "x"
    cmd = ["python3", "/app/render.py", "--routes", "/app/config/routes.yaml", "--out", str(out), "--admin", ""]
    subprocess.run(cmd, check=True)
    first = hashlib.md5(out.read_bytes()).digest()
    temporary_mtime = out.stat().st_mtime_ns
    subprocess.run(cmd, check=True)
    assert first == hashlib.md5(out.read_bytes()).digest()
    assert out.stat().st_mtime_ns == temporary_mtime
    assert live.stat().st_mtime_ns == mtime
    # 域名模型的三种非法输入都必须被拒：缺 subdomain / 非法 subdomain / 重复 subdomain
    cases = {
        "missing": "routes:\n  - path: /broken\n    upstream: x:1\n",
        "invalid": "routes:\n  - subdomain: Bad_Name\n    upstream: x:1\n",
        "duplicate": "routes:\n  - subdomain: dup\n    upstream: x:1\n  - subdomain: dup\n    upstream: y:2\n",
    }
    # 先打草稿产物，回归时不会污染共享的线上文件
    saved = out.read_bytes()
    for name, body in cases.items():
        invalid = Path(directory) / f"routes-{name}.yaml"
        invalid.write_text(body)
        result = subprocess.run(["python3", "/app/render.py", "--routes", str(invalid), "--out", str(out), "--admin", ""])
        assert result.returncode != 0, f"{name} should be rejected"
        assert out.read_bytes() == saved, f"{name} corrupted the scratch output"
        result = subprocess.run(["python3", "/app/render.py", "--routes", str(invalid), "--out", str(live), "--admin", ""])
        assert result.returncode != 0, f"{name} should be rejected for the live file"
        assert live.read_bytes() == before, f"{name} corrupted the live Caddyfile"
        assert live.stat().st_mtime_ns == mtime, f"{name} touched the live Caddyfile"
'
    [ "$status" -eq 0 ]
}
