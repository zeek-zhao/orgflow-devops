#!/usr/bin/env python3
"""重算 users.ldif 里的 {SSHA} 哈希：把「仓库里带一个已知口令」这件事去掉。

为什么需要它：`users.ldif` 里 10 个账号原先共用口令 `123456` 的 `{SSHA}`。公开仓库
里挂着一份人人可用的目录初始口令，等于把 LDAP 的入口一起公开；而且同一个 `123456`
当时还是部署机上真实在用的口令，不只是示例。

做法：口令真值只在操作者手里（`ORGFLOW_INITIAL_PASSWORD` 或 `--password`，都不入
仓库），仓库里只留随机口令的哈希 —— 哈希没人能反推，公开也不构成凭据泄漏。
每个账号**各自一份 salt**，所以同一个口令在同目录里不会出现相同哈希，横向看一眼
哈希是否相同无法判断两个人是不是同口令。

用法：
    python scripts/gen-ldif-passwords.py                      # 随机生成，口令打印一次
    ORGFLOW_INITIAL_PASSWORD='...' python scripts/gen-ldif-passwords.py
    python scripts/gen-ldif-passwords.py --dry-run             # 只看会改什么

重建目录之后，把这句口令记进部署机的 `.env`（`ORGFLOW_INITIAL_PASSWORD`），否则下次
换机器又得重算。
"""
from __future__ import annotations

import argparse
import base64
import hashlib
import os
import pathlib
import re
import secrets
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
USERS = ROOT / "services" / "auth" / "ldif" / "users.ldif"

# OpenLDAP `slappasswd -h {SSHA}` 的默认 salt 是 8 字节，摘要 20 字节，base64 后 40 字符。
SALT_BYTES = 8
PASSWORD_LINE = re.compile(r"^userpassword: \{SSHA\}.*$", re.IGNORECASE | re.MULTILINE)

# 口令长度下限：这个值只在运维手输时生效；随机生成路径恒定 32 字符，远高于它。
MIN_LENGTH = 12


def ssha(password: bytes, salt: bytes) -> str:
    digest = hashlib.sha1(password + salt).digest()
    return "{SSHA}" + base64.b64encode(digest + salt).decode("ascii")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--password", help="口令真值；缺省读 ORGFLOW_INITIAL_PASSWORD")
    parser.add_argument("--dry-run", action="store_true", help="只报告，不写文件")
    args = parser.parse_args()

    explicit = args.password or os.environ.get("ORGFLOW_INITIAL_PASSWORD")
    if explicit:
        if len(explicit) < MIN_LENGTH:
            print(f"✗ 口令至少 {MIN_LENGTH} 字符（当前 {len(explicit)}）", file=sys.stderr)
            return 2
        password = explicit
        source = "给定值"
    else:
        # token_urlsafe(24) 约 32 字符，字母数字加 -_，可直接粘进 .env 不用转义。
        password = secrets.token_urlsafe(24)
        source = "随机生成"

    if not USERS.is_file():
        print(f"✗ 找不到 {USERS}", file=sys.stderr)
        return 1

    text = USERS.read_text(encoding="utf-8")
    count = len(PASSWORD_LINE.findall(text))
    if not count:
        print("✗ users.ldif 里没有 userpassword: {SSHA}... 行，改法可能已过时", file=sys.stderr)
        return 1

    # 逐行换，保证每个账号一份独立 salt。
    updated = PASSWORD_LINE.sub(
        lambda _m: "userpassword: " + ssha(password.encode("utf-8"), secrets.token_bytes(SALT_BYTES)),
        text,
    )

    if args.dry_run:
        print(f"[dry-run] 将重算 {count} 个账号的哈希（口令来源：{source}）")
        return 0

    USERS.write_text(updated, encoding="utf-8")
    print(f"✓ 已重算 {count} 个账号的 {{{{SSHA}}}} 哈希（口令来源：{source}）", file=sys.stderr)
    # 口令只打印一次、走 stdout；调用方自行决定收进 .env 还是密码库，不要贴进 issue。
    print(password)
    return 0


if __name__ == "__main__":
    sys.exit(main())
