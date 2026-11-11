#!/usr/bin/env python3
"""LDIF 口令自检（纳入 make test）。

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
  4. 每条哈希都**不能**是常见弱口令的哈希 —— 判据从「必须等于 123456」翻转而来：
     公开仓库里挂着一份人人可用的目录口令，本身就是把 LDAP 入口一起公开
  5. 各账号 salt 互不相同 —— 否则一眼看出谁和谁同口令，等于免费的弱口令地图

第 4 条为什么用字典而不是「等于某个值」：原先的写法要求所有账号都是 123456，
于是这条测试反而在**保护**一个弱口令。改成黑名单后，它能挡住「换了个别的弱口令」
这种更常见的退化。

反证用法：
  - 把任一 `+` 改回 `\\+`                          -> 第 1、3 条红
  - 把某条哈希换成 123456 的 {SSHA}                 -> 第 4 条红
  - 复制某账号的 userPassword 到另一个账号            -> 第 5 条红
  - 删掉某条目的 userPassword                       -> 第 2 条红

本脚本只做静态检查；导入后的实际 bind 由部署侧逐账号 `ldapwhoami` 验收。
"""
import base64
import hashlib
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
USERS = ROOT / 'services' / 'auth' / 'ldif' / 'users.ldif'
EXPECTED_USERS = 10

# 仓库存量文档里也不该再出现这个口令真值（README 曾经直接把它写成初始密码）。
DOCS_TO_SCAN = [
    ROOT / 'services' / 'auth' / 'README.md',
    ROOT / 'docs' / 'services' / 'ldap.md',
]

# 常见弱口令黑名单：这些值出现在目录里，等于没有口令。
# 只放最高频的一小撮 —— 目的是拦住退化，不是做完整的口令审计。
WEAK_PASSWORDS = (
    b'123456', b'1234567', b'12345678', b'123456789', b'1234567890',
    b'password', b'password1', b'passw0rd', b'changeme', b'change-me',
    b'admin', b'admin123', b'root', b'secret', b'qwerty', b'letmein',
    b'orgflow', b'devops', b'test', b'test123', b'abc123', b'111111',
)


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
    seen_salts = {}
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

        weak = [p.decode('ascii', 'replace') for p in WEAK_PASSWORDS
                if hashlib.sha1(p + salt).digest() == digest]
        if weak:
            fails.append('%s: 口令是常见弱口令之一（%s）；用 '
                         'scripts/gen-ldif-passwords.py 重算' % (label, ', '.join(weak)))

        if salt in seen_salts:
            fails.append('%s: salt 与 %s 相同（同口令会暴露成相同哈希）'
                         % (label, seen_salts[salt]))
        else:
            seen_salts[salt] = label
        checked += 1

    for doc in DOCS_TO_SCAN:
        if not doc.is_file():
            continue
        body = doc.read_text(encoding='utf-8')
        if re.search(r'123456', body):
            fails.append('%s: 仍写着口令真值 123456；改口径为「口令由操作者掌握、'
                         '仓库只存哈希」' % doc.relative_to(ROOT))

    if fails:
        print('✗ LDIF 口令自检失败：', file=sys.stderr)
        for f in fails:
            print('  - %s' % f, file=sys.stderr)
        return 1

    print('✓ LDIF 口令自检通过：%d 个账号的 {SSHA} 结构合规、salt 互不相同、'
          '且都不是常见弱口令' % checked)
    return 0


if __name__ == '__main__':
    sys.exit(main())
