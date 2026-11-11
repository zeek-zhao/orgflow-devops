#!/usr/bin/env python3
"""ldap-set-passwords.sh 的静态自检（纳入 make test）。

为什么需要它：`users.ldif` 里只剩哈希，运行中的目录靠 `ldapmodify` 同步口令。
这个脚本一旦解析错（LDIF 加账号、DN 换了 ou、口令读错键），表现是「某几个账号
登不进去」，而 CI 上只看到 401/49 —— 定位成本很高。所以把「能覆盖全部账号」
「口令不外泄」这两件事做成离线断言，不进容器也能跑。

判据（任一不满足即非 0 退出）：
  1. `--dry-run` 成功，且覆盖 users.ldif 里全部 uid 条目（数量与 DN 逐条对齐）
  2. `--dry-run` 的输出里**不含**口令真值（只出现 ***）
  3. .env 里缺 ORGFLOW_INITIAL_PASSWORD 时必须失败（不能悄悄用空口令）
  4. 口令短于 12 字符时必须失败

反证：把 USERS_LDIF 指向一个只含 9 个账号的副本 -> 第 1 条红；
      把 dry-run 的 sed 去掉 -> 第 2 条红。
"""
from __future__ import annotations

import os
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
SCRIPT = ROOT / "scripts" / "ldap-set-passwords.sh"
USERS = ROOT / "services" / "auth" / "ldif" / "users.ldif"
MIN_LENGTH = 12

fails: list[str] = []


def run(env_file: str, users: str | None = None):
    # 一律传**相对路径**：Git Bash 会把 Windows 绝对路径里的反斜杠吃掉
    # （`D:\zeek\...` 变成 `D:zeek...`），而且 cwd 已经在仓库根，相对路径两边都认。
    env = dict(os.environ)
    env["ENV_FILE"] = env_file
    env.pop("ORGFLOW_INITIAL_PASSWORD", None)
    if users is not None:
        env["USERS_LDIF"] = users
    return subprocess.run(
        ["bash", "scripts/ldap-set-passwords.sh", "--dry-run"],
        cwd=ROOT, env=env, capture_output=True, text=True,
    )


def write_env(path: pathlib.Path, password: str | None) -> None:
    lines = ["LDAP_DOMAIN=devops.com\n"]
    if password is not None:
        lines.append(f"ORGFLOW_INITIAL_PASSWORD={password}\n")
    path.write_text("".join(lines), encoding="utf-8")


def native_bash() -> bool:
    """PATH 里的 bash 能不能按本机路径跑。

    Windows 上 `bash` 常常解析到 `C:\\Windows\\System32\\bash.exe`（WSL 启动器）：
    cwd 被映射成 `/mnt/d/...`、环境变量也不保证透传，跑这个脚本只会得到
    「文件不存在」的假红 —— 而假红比没有测试更糟，所以干脆在 Windows 上跳过。
    CI（ubuntu）与 WSL 内的原生 bash 才是这脚本的真实运行环境。
    """
    if os.name == "nt":
        return False
    return shutil.which("bash") is not None


def main() -> int:
    if not native_bash():
        print("PATH 里没有可直接使用的 bash（WSL 启动器不算），跳过 ldap-set-passwords.sh 自检")
        return 0

    expected = [line.split(":", 1)[1].strip()
                for line in USERS.read_text(encoding="utf-8").splitlines()
                if re.match(r"(?i)^dn: uid=[^,]+,ou=users,", line)]

    with tempfile.TemporaryDirectory(dir=ROOT / "out", prefix="ldap-pw-") as tmp:
        # 临时目录放在 out/ 下，才能用相对路径传给 bash
        rel = pathlib.Path(tmp).relative_to(ROOT).as_posix()
        good = f"{rel}/good.env"
        write_env(ROOT / good, "Test-Password-For-CI-0123456789")

        # 1 + 2：覆盖全部账号，且口令不外泄
        proc = run(good)
        if proc.returncode != 0:
            fails.append(f"dry-run 应成功，实际 rc={proc.returncode}: {proc.stderr.strip()[:200]}")
        output = proc.stdout
        missing = [dn for dn in expected if dn not in output]
        if missing:
            fails.append(f"dry-run 漏了 {len(missing)} 个账号: {missing[:3]}")
        if "Test-Password-For-CI-0123456789" in output:
            fails.append("dry-run 把口令真值打印出来了（应只出现 ***）")
        if "***" not in output:
            fails.append("dry-run 输出里没有 *** 占位，无法判断是否脱敏")

        # 3：缺字段必须失败
        missing_key = f"{rel}/missing.env"
        write_env(ROOT / missing_key, None)
        proc = run(missing_key)
        if proc.returncode == 0:
            fails.append("缺 ORGFLOW_INITIAL_PASSWORD 时仍然成功（会静默使用空口令）")

        # 4：过短的口令必须失败
        short = f"{rel}/short.env"
        write_env(ROOT / short, "a" * (MIN_LENGTH - 1))
        proc = run(short)
        if proc.returncode == 0:
            fails.append(f"口令短于 {MIN_LENGTH} 字符时仍然成功")

    if fails:
        for item in fails:
            print(f"✗ {item}")
        return 1
    print(f"ldap-set-passwords 自检通过（{len(expected)} 个账号，口令不出现在输出中）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
