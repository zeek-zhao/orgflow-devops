#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

# Python's standard library suffices: edit only the two service blocks and
# the Compose extension, preserving upstream pins and comments verbatim.
python3 - <<'PY'
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

prefix = "ghcr.io/zeek-zhao/orgflow-devops"
tag = os.environ.get("IMAGES_TAG", "latest")
if not re.fullmatch(r"[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}", tag):
    sys.exit("IMAGES_TAG must be a valid image tag")
images = {}
for name in ("router", "jjb", "m0-test"):
    reference = f"{prefix}/{name}:{tag}"
    try:
        result = subprocess.run(
            ["docker", "buildx", "imagetools", "inspect", reference],
            check=True, capture_output=True, text=True,
        )
    except (OSError, subprocess.CalledProcessError) as error:
        detail = error.stderr if isinstance(error, subprocess.CalledProcessError) else str(error)
        sys.exit(f"{reference}: digest 解析失败；先跑 images.yml 工作流，并确认 GHCR 登录权限。\n{detail}")
    digests = re.findall(r"^Digest:\s+(sha256:[a-f0-9]{64})\s*$", result.stdout, re.MULTILINE)
    if len(digests) != 1:
        sys.exit(f"{reference}: digest 缺失或不唯一；先跑 images.yml 工作流")
    images[name] = f"{prefix}/{name}:24.04-v1@{digests[0]}"

path = Path("docker-compose.ghcr.yml")
text = path.read_text()
services = re.search(r"^services:[ \t]*\n(?:[ \t]+[^\n]*\n|\n)*", text, re.MULTILINE)
if services is None:
    sys.exit(f"{path}: missing services block")
block = services.group()
for name in ("router", "jjb"):
    replacement = f"  {name}:\n    image: {images[name]}\n"
    pattern = rf"^  {name}:[^\n]*\n(?:[ \t]{{3,}}[^\n]*\n)*"
    if re.search(pattern, block, re.MULTILINE):
        block, count = re.subn(pattern, replacement, block, flags=re.MULTILINE)
        if count != 1:
            sys.exit(f"{path}: duplicate {name} service")
    else:
        block = block.rstrip("\n") + "\n" + replacement
text = text[:services.start()] + block + text[services.end():]
extension = f"x-m0-test-image: {images['m0-test']}\n"
if re.search(r"^x-m0-test-image:", text, re.MULTILINE):
    text, count = re.subn(r"^x-m0-test-image:[^\n]*\n?", extension, text, flags=re.MULTILINE)
    if count != 1:
        sys.exit(f"{path}: duplicate x-m0-test-image")
else:
    text = text.rstrip("\n") + "\n\n" + extension

temporary = None
try:
    with tempfile.NamedTemporaryFile(mode="w", dir=path.parent, delete=False) as stream:
        temporary = Path(stream.name)
        stream.write(text)
    os.chmod(temporary, path.stat().st_mode & 0o777)
    subprocess.run(
        ["docker", "compose", "-f", "docker-compose.yml", "-f", str(temporary), "config", "-q"],
        check=True,
    )
    temporary.replace(path)
finally:
    if temporary is not None:
        temporary.unlink(missing_ok=True)
for name, reference in images.items():
    print(f"{name} {reference}")
print(f"Updated {path}; upstream digests and tests/images.lock are unchanged.")
PY
