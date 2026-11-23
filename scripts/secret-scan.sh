#!/usr/bin/env bash
# secret-scan.sh —— 无密入库门禁（NFR-06 / AC-12）
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
if ! command -v gitleaks >/dev/null 2>&1; then echo "⚠ gitleaks 未安装，跳过（CI 环境必装）"; exit 0; fi
gitleaks detect --no-banner --source . && echo "✓ 密钥扫描 0 命中"
