#!/usr/bin/env python3
"""Read-only deployment diagnostics; never starts, pulls, or builds containers."""
import json
import os
from pathlib import Path
import shlex
import shutil
import socket
import subprocess
import sys


def run(command):
    return subprocess.run(command, capture_output=True, text=True, timeout=30)


def main():
    failed = False
    print("== M0 环境自检（只读，不启动容器） ==", flush=True)
    for tool in ("docker", "bash", "python3", "curl"):
        location = shutil.which(tool)
        print(f"[{'OK' if location else 'FAIL'}] {tool}: {location or '未安装'}")
        failed |= location is None
    if not shutil.which("docker"):
        return 1

    compose = shlex.split(os.environ.get("COMPOSE", "docker compose"))
    for label, command in (("Docker", ["docker", "--version"]),
                           ("Compose", compose + ["version"])):
        result = run(command)
        print(f"[{'OK' if result.returncode == 0 else 'FAIL'}] {label}: "
              f"{result.stdout.strip() or result.stderr.strip()}")
        failed |= result.returncode != 0
    info = run(["docker", "info", "--format", "{{json .DockerRootDir}}"])
    if info.returncode:
        print("[FAIL] Docker daemon 不可用，请检查服务状态和 socket 权限")
        failed = True
    else:
        print("[OK] Docker daemon 可访问")

    env_file = Path(os.environ.get("ENV_FILE", ".env"))
    if env_file.is_file():
        print(f"[OK] {env_file} 已存在（不显示密钥）")
    else:
        print(f"[WARN] {env_file} 不存在；make deploy 仅为默认 dev .env 自动生成随机密钥")
    config_env = env_file if env_file.is_file() else Path(".env.example")
    command = compose + ["--env-file", str(config_env)]
    result = run(command + ["config", "--format", "json"])
    if result.returncode:
        # A malformed dotenv/config error can contain a literal secret.
        print("[FAIL] Compose 配置解析失败，请本地检查 YAML / env 文件格式（不输出敏感正文）")
        return 1
    config = json.loads(result.stdout)
    running = run(command + ["ps", "--format", "json"])
    published = set()
    if running.returncode == 0:
        text = running.stdout.strip()
        containers = json.loads(text) if text.startswith("[") else [
            json.loads(line) for line in text.splitlines()
        ]
        published = {
            entry["PublishedPort"] for container in containers
            for entry in container.get("Publishers") or [] if entry.get("PublishedPort")
        }

    for name, service in config["services"].items():
        for port in service.get("ports", []):
            number = int(port["published"])
            with socket.socket() as sock:
                try:
                    sock.bind((port.get("host_ip", "0.0.0.0"), number))
                except OSError:
                    if number in published:
                        print(f"[OK] 端口 {number} ({name}) 已由当前 Compose 项目使用")
                    else:
                        print(f"[FAIL] 端口 {number} ({name}) 已占用或无法绑定")
                        failed = True
                else:
                    print(f"[OK] 端口 {number} ({name}) 可绑定")
        if service.get("profiles"):
            continue
        image = service.get("image", f"{config['name']}-{name}")
        image_result = run(["docker", "image", "inspect", image, "--format", "{{.Id}}"])
        if image_result.returncode == 0:
            print(f"[OK] 镜像 {name}: {image} 已就绪")
        else:
            action = "本地构建" if "build" in service else "下载（需访问镜像仓库）"
            print(f"[WARN] 镜像 {name}: {image} 不在本地，deploy 将{action}")

    paths = [Path.cwd()]
    if info.returncode == 0:
        root = Path(json.loads(info.stdout))
        if root.is_dir():
            paths.append(root)
        else:
            print("[WARN] Docker 数据目录在本机不可见，请在 daemon 主机检查磁盘余量")
    for path in paths:
        free = shutil.disk_usage(path).free / (1024 ** 3)
        print(f"[{'OK' if free >= 5 else 'WARN'}] 磁盘 {path}: 可用 {free:.1f} GiB"
              + ("（建议至少 5 GiB，另预留 Nexus/Jenkins 数据空间）" if free < 5 else ""))
    return int(failed)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, subprocess.TimeoutExpired) as error:
        print(f"[FAIL] 自检无法完成: {type(error).__name__}；请检查命令、配置及 Docker 响应",
              file=sys.stderr)
        sys.exit(1)
