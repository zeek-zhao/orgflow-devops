#!/usr/bin/env bats
setup() {
    load 'helpers/common'
    setup_http
}

@test "router: health, idempotent output and rejected invalid input" {
    run compose_exec router python3 -c "import urllib.request;print(urllib.request.urlopen('http://127.0.0.1:8090/healthz',timeout=5).status)"
    [ "$status" -eq 0 ]
    [ "$output" = 200 ]
    run compose_exec router python3 -c '
import hashlib, os, subprocess, tempfile
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
    # First reject against a scratch artifact, so a regression cannot damage the shared live file.
    invalid = Path(directory) / "routes.yaml"
    invalid.write_text("routes:\n  - path: /broken\n")
    saved = out.read_bytes()
    result = subprocess.run(["python3", "/app/render.py", "--routes", str(invalid), "--out", str(out), "--admin", ""])
    assert result.returncode != 0
    assert out.read_bytes() == saved
    result = subprocess.run(["python3", "/app/render.py", "--routes", str(invalid), "--out", str(live), "--admin", ""])
    assert result.returncode != 0
    assert live.read_bytes() == before
    assert live.stat().st_mtime_ns == mtime
'
    [ "$status" -eq 0 ]
}
