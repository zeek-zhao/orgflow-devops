#!/usr/bin/env python3
"""LDIF 口令真值自检（纳入 make test）。

背景（2026-11-06 线上切换前预演实测）：
  `services/auth/ldif/users.ldif` 里 `{SSHA}` 的 base64 值含 `+` 时，曾被写成
  `\\+`。`ldapadd` 导入**不会**把它还原成 `+`，反斜杠会留在 userPassword 值里，
  导致该账号 simple bind 永久返回 `Invalid credentials (49)`。
  当时 10 个账号里只有 2 个（哈希恰好不含 `+`）能登录，极具迷惑性。

判据（任一不满足即非 0 退出）：
  1. users.ldif 中不得出现 `\\+`
  2. 每个 posixAccount 必须有 `userPassword: {SSHA}<base64>`
  3. base64 严格可解码，且解码后 > 20 字节（前 20 字节是 SHA1 摘要，其余是 salt；
     OpenLDAP `slappasswd -h {SSHA}` 默认 salt 8 字节，总共 28 字节，不是 40）
  4. SHA1(b'123456' + salt) 必须等于存下的摘要 —— 即口令真值确实是 123456

反证用法：
  - 把任一 `+` 改回 `\\+`                    -> 第 1、3 条红
  - 改动哈希里的一个字符                      -> 第 4 条红
  - 删掉某条目的 userPassword                 -> 第 2 条红

本脚本只做静态检查；导入后的实际 bind 由部署侧逐账号 `ldapwhoami` 验收。
"""
import base64
import hashlib
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
USERS = ROOT / 'services' / 'auth' / 'ldif' / 'users.ldif'
PASSWORD = b'123456'
EXPECTED_USERS = 10


def main():
    if not USERS.is_file():
        print('✗ 找不到 %s' % USERS, file=sys.stderr)
        return 1

    text = USERS.read_text(encoding='utf-8')
    fails = []

    escaped = text.count('\\+')
    if escaped:
        fails.append('users.ldif 仍有 %d 处 \\+；LDIF 导入会保留反斜杠并污染 SSHA，'
                     '必须写成普通 +' % escaped)

    blocks = [b for b in text.split('\n\n')
              if re.search(r'^dn: ', b, re.M)]
    users = [b for b in blocks
             if re.search(r'^objectclass: posixAccount$', b, re.M | re.I)]
    if len(users) != EXPECTED_USERS:
        fails.append('posixAccount 条目应为 %d 个，实际 %d 个'
                     % (EXPECTED_USERS, len(users)))

    checked = 0
    for blk in users:
        dn = re.search(r'^dn: (.+)$', blk, re.M)
        label = dn.group(1) if dn else '<无 DN>'
        m = re.search(r'^userpassword:\s*\{SSHA\}(\S+)\s*$', blk, re.M | re.I)
        if not m:
            fails.append('%s: 缺少 userPassword: {SSHA}...' % label)
            continue
        val = m.group(1)
        try:
            raw = base64.b64decode(val, validate=True)
        except Exception as exc:
            fails.append('%s: {SSHA} 的 base64 无法严格解码（%s）：%r'
                         % (label, exc, val))
            continue
        if len(raw) <= 20:
            fails.append('%s: SSHA 解码后应 > 20 字节（20 摘要 + salt），实际 %d 字节'
                         % (label, len(raw)))
            continue
        digest, salt = raw[:20], raw[20:]
        if hashlib.sha1(PASSWORD + salt).digest() != digest:
            fails.append('%s: {SSHA} 摘要与口令 123456 不匹配' % label)
        checked += 1

    if fails:
        print('✗ LDIF 口令自检失败：', file=sys.stderr)
        for f in fails:
            print('  - %s' % f, file=sys.stderr)
        return 1

    print('✓ LDIF 口令自检通过：%d 个账号的 {SSHA} 均对应 123456，无 \\+ 转义，'
          'base64 与 SSHA 结构合规' % checked)
    return 0


if __name__ == '__main__':
    sys.exit(main())
