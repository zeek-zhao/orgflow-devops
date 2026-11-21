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

# IMAGES_TAG 只用于「合并前验收」：拿某个 sha-<短哈希> 标签的镜像先验一遍。
# 正常回写**不使用**它 —— 每个镜像的 tag 是版本语义（jenkins 是 24.04-v3，
# 其余是 24.04-v1），统一写死会把 jenkins 标成 v1 却挂 v3 的 digest。
override = os.environ.get("IMAGES_TAG", "")
if override and not re.fullmatch(r"[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}", override):
    sys.exit("IMAGES_TAG must be a valid image tag")

path = Path("docker-compose.ghcr.yml")
overlay_text = path.read_text()


def current_tag(name):
    """沿用该镜像当前登记的 tag：覆盖层优先，其次 tests/images.lock，最后 24.04-v1。"""
    match = re.search(
        rf"^  {re.escape(name)}:\n    image: {re.escape(prefix)}/{re.escape(name)}:([^@\s]+)@",
        overlay_text,
        re.MULTILINE,
    )
    if match:
        return match.group(1)
    lock = Path("tests/images.lock")
    if lock.is_file():
        for line in lock.read_text().splitlines():
            fields = line.split("\t")
            if len(fields) == 3 and fields[1].startswith(f"{prefix}/{name}:"):
                return fields[1].rsplit(":", 1)[1]
    return "24.04-v1"


images = {}
for name in ("router", "jjb", "m0-test", "dnsmasq", "jenkins", "jenkins-agent"):
    tag = override or current_tag(name)
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
    images[name] = f"{reference}@{digests[0]}"

# pinned-at：这批 digest 是**哪次提交**的源码编出来的。scripts/check-image-source.sh
# 用它判断「镜像是否落后于源码」—— 没有它，闸门只能退化成「HEAD 是否等于
# origin/main」那种天天误报的判据。没有 git 元数据时写 unknown（zip 副本）。
pinned_at = os.environ.get("PINNED_AT_SHA", "").strip()
if not pinned_at:
    probe = subprocess.run(["git", "-C", ".", "rev-parse", "HEAD"],
                           capture_output=True, text=True)
    pinned_at = probe.stdout.strip() if probe.returncode == 0 else "unknown"
if not re.fullmatch(r"(unknown|[0-9a-f]{7,40})", pinned_at):
    sys.exit(f"PINNED_AT_SHA 不是合法提交哈希：{pinned_at}")


path = Path("docker-compose.ghcr.yml")
text = overlay_text
services = re.search(r"^services:[ \t]*\n(?:[ \t]+[^\n]*\n|\n)*", text, re.MULTILINE)
if services is None:
    sys.exit(f"{path}: missing services block")
block = services.group()
for name in ("router", "jjb", "dnsmasq", "jenkins", "jenkins-agent"):
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

# pinned-at 行放在 services: 之前，紧贴被它约束的那一块；先删后插保证幂等。
text = re.sub(r"^# pinned-at:[^\n]*\n", "", text, flags=re.MULTILINE)
text, count = re.subn(r"^(services:)", f"# pinned-at: {pinned_at}\n\\1", text,
                      count=1, flags=re.MULTILINE)
if count != 1:
    sys.exit(f"{path}: 找不到 services: 行，无法写入 pinned-at")

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
