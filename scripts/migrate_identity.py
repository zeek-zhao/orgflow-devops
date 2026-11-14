#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""#85 / REQ-M0-A2：LDAP 身份全量重命名（唯一真源 = docs/身份命名规范.md §3）。

用法：
  python3 scripts/migrate_identity.py --check          # 只报告当前状态，不写文件
  python3 scripts/migrate_identity.py --apply          # 执行仓库侧迁移（幂等）
  python3 scripts/migrate_identity.py --rollback-ldif  # 输出线上回滚 LDIF 到 stdout
  python3 scripts/migrate_identity.py --verify         # 迁移后静态验收，不通过则非 0 退出

边界：本脚本**只改仓库文件**。线上 LDAP 的迁移/回滚由人工在授权窗口执行，
`--rollback-ldif` 只负责生成回滚用的 LDIF，不连任何 LDAP。
"""
import io
import os
import pathlib
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
os.chdir(ROOT)

USERS = 'services/auth/ldif/users.ldif'
GROUPS = 'services/auth/ldif/app.ldif'

# 唯一真源：docs/身份命名规范.md §3。key = 旧 uid, value = (新 uid, 是否人账号)
MAPPING = {
    'zeek.zhao':        ('zeek.zhao', True),
    'admin.zeek':       ('svc-platform-admin', False),
    'dev.zeek':         ('svc-platform-dev', False),
    'devops.qa':        ('svc-platform-qa', False),
    'gerrit.anonymous': ('svc-gerrit-anonymous', False),
    'gerrit.dev':       ('svc-gerrit-dev', False),
    'nexus.anonymous':  ('svc-nexus-anonymous', False),
    'nexus.dev':        ('svc-nexus-dev', False),
    'admin.jira':       ('svc-jira-admin', False),
    'dev.jira':         ('svc-jira-dev', False),
}

# 运行真本：这些文件里的旧 uid 必须全部改成新 uid
REF_FILES = [
    'docs/账号与登录.md',
    'docs/services/ldap.md',
    'docs/services/dex.md',
    'docs/engineering/M0-测试体系.md',
    'services/auth/README.md',
    'tests/bats/10_ldap.bats',
]

# 历史/规格类：旧 uid 是「映射记录」或「历史事实」，必须保留。
# 其中三份（命名规范 / task-cards / 会话交接）已按最小披露移出仓库；条目留着无害 ——
# 文件不存在就永远匹配不上。真回来了，先拦的是 check-public-redaction.sh 的「内部文档」判据。
ALLOW_OLD = [
    'docs/身份命名规范.md',        # §3 映射表本身
    'docs/早期内部需求表（已不随仓库分发）',     # 需求取证记录
    'docs/task-cards/84-identity-naming.md',
    'docs/task-cards/85-ldap-rename.md',
    'docs/task-cards/02-auth-stack.md',
    'docs/会话交接.md',
    'docs/待办.md',
    'scripts/migrate_identity.py',   # 映射表定义本身
]

DN_RE = re.compile(r'^cn=(?P<cn>.+),ou=users,dc=devops,dc=com$')


def read(p):
    return io.open(p, encoding='utf-8', newline='').read()


def write(p, s):
    io.open(p, 'w', encoding='utf-8', newline='').write(s)


def parse_entries(text):
    """按空行切块，返回 [(start_line_idx, [lines])]。"""
    blocks, cur = [], []
    for ln in text.split('\n'):
        if ln.strip() == '':
            if cur:
                blocks.append(cur)
                cur = []
        else:
            cur.append(ln)
    if cur:
        blocks.append(cur)
    return blocks


def current_uids():
    out = []
    for blk in parse_entries(read(USERS)):
        uid = next((l[5:].strip() for l in blk if l.startswith('uid: ')), None)
        if uid:
            out.append(uid)
    return out


def report_state():
    uids = current_uids()
    print('users.ldif 当前 uid（%d 个）：' % len(uids))
    for u in uids:
        if u in MAPPING:
            print('  %-18s -> %s' % (u, MAPPING[u][0]))
        else:
            print('  %-18s (不在映射表内)' % u)
    pending = [u for u in uids if u in MAPPING and MAPPING[u][0] != u]
    print('\n待迁移 %d 个，已完成 %d 个' % (len(pending), len(uids) - len(pending)))
    return pending


def rewrite_users(text):
    """按映射表重写 users.ldif；对已迁移条目幂等。"""
    out = []
    for blk in parse_entries(text):
        uid = next((l[5:].strip() for l in blk if l.startswith('uid: ')), None)
        if not uid or uid not in MAPPING:
            out.append('\n'.join(blk))
            continue
        new, is_human = MAPPING[uid]
        has_displayname = any(l.startswith('displayname:') for l in blk)
        newblk = []
        for ln in blk:
            if ln.startswith('# Entry'):
                ln = re.sub(r'cn=[^,]+,ou=users', 'uid=%s,ou=users' % new, ln)
            elif ln.startswith('dn: '):
                ln = 'dn: uid=%s,ou=users,dc=devops,dc=com' % new
            elif ln.startswith('uid: '):
                ln = 'uid: %s' % new
            elif ln.startswith('mail: '):
                ln = 'mail: %s@devops.com' % new
            elif ln.startswith('homedirectory: '):
                ln = 'homedirectory: /home/users/%s' % new
            elif not is_human and ln.startswith('cn: '):
                ln = 'cn: %s' % new
            elif not is_human and ln.startswith('givenname: '):
                ln = 'givenname: %s' % new
            elif not is_human and ln.startswith('sn: '):
                ln = 'sn: %s' % new
            newblk.append(ln)
            # displayName 紧跟 sn 之后插入（§2.2 必填属性）；已有则不重复插
            if ln.startswith('sn: ') and not has_displayname:
                dn_val = 'Zeek Zhao' if is_human else new
                newblk.append('displayname: %s' % dn_val)
        out.append('\n'.join(newblk))
    # 保留原始尾随空行数量：用空行重连
    return '\n\n'.join(out) + '\n'


def replace_refs(text):
    for old in sorted(MAPPING, key=len, reverse=True):
        new = MAPPING[old][0]
        if old == new:
            continue
        text = text.replace(old, new)
    return text


def apply():
    changed = []
    u = read(USERS)
    nu = rewrite_users(u)
    if nu != u:
        write(USERS, nu)
        changed.append(USERS)
    g = read(GROUPS)
    ng = replace_refs(g)
    if ng != g:
        write(GROUPS, ng)
        changed.append(GROUPS)
    for p in REF_FILES:
        if not os.path.exists(p):
            print('  ! 缺文件，跳过: %s' % p)
            continue
        t = read(p)
        nt = replace_refs(t)
        if nt != t:
            write(p, nt)
            changed.append(p)
    print('已改写 %d 个文件：' % len(changed))
    for p in changed:
        print('  ' + p)


def verify():
    fails = []
    uids = current_uids()
    print('迁移后 uid（%d 个）：%s' % (len(uids), ', '.join(uids)))
    stale = [u for u in uids if u in MAPPING and MAPPING[u][0] != u]
    if stale:
        fails.append('仍有未迁移的旧 uid: %s' % ', '.join(stale))

    expected = sorted(v[0] for v in MAPPING.values())
    if sorted(uids) != expected:
        fails.append('uid 集合与 §3 映射表不一致：实际=%s 期望=%s' % (sorted(uids), expected))

    # DN 形式
    for blk in parse_entries(read(USERS)):
        dn = next((l[4:].strip() for l in blk if l.startswith('dn: ')), '')
        uid = next((l[5:].strip() for l in blk if l.startswith('uid: ')), None)
        if uid is None:
            continue
        if dn != 'uid=%s,ou=users,dc=devops,dc=com' % uid:
            fails.append('DN 不合规: %r（uid=%s）' % (dn, uid))

    # uidNumber 唯一
    nums = [l.split(':')[1].strip() for blk in parse_entries(read(USERS))
            for l in blk if l.startswith('uidnumber: ')]
    if len(nums) != len(set(nums)):
        fails.append('uidNumber 有重复: %s' % nums)

    # memberUid 必须能解析
    refs = [l.split(':', 1)[1].strip() for blk in parse_entries(read(GROUPS))
            for l in blk if l.startswith('memberuid: ')]
    dangling = sorted(set(r for r in refs if r not in uids))
    if dangling:
        fails.append('悬空 memberUid: %s' % ', '.join(dangling))

    # 旧 uid 只允许出现在历史/规格文件
    print('\n旧 uid 残留扫描（allowlist 之外必须为 0）：')
    oldpat = re.compile('|'.join(re.escape(k) for k in MAPPING if MAPPING[k][0] != k))
    hits = 0
    for dirpath, _d, files in os.walk('.'):
        # 路径一律转成 POSIX 形式再比对：`os.path.normpath` 在 Windows 上产出反斜杠，
        # 而下面的 '/' 前缀与 ALLOW_OLD 的正斜杠永远匹配不上 —— 表现为「allowlist 失效 +
        # out/ 没被排除」，本机 `make test` 恒红，而 Linux CI 全绿。这类假红最误导人。
        rel_dir = pathlib.PurePath(dirpath).as_posix()
        if any(x in rel_dir for x in ('/.git', '/out', '/.jjb', '/node_modules')):
            continue
        for fn in files:
            if not fn.endswith(('.md', '.bats', '.py', '.sh', '.yaml', '.yml', '.ldif')):
                continue
            p = pathlib.PurePath(dirpath, fn).as_posix()
            if p.startswith('./'):
                p = p[2:]
            if p in ALLOW_OLD:
                continue
            for i, ln in enumerate(read(p).split('\n'), 1):
                if oldpat.search(ln):
                    hits += 1
                    print('  ✗ %s:%d  %s' % (p, i, ln.strip()[:110]))
    if hits:
        fails.append('allowlist 之外仍有 %d 处旧 uid 引用' % hits)
    else:
        print('  ✓ 0 处')

    print()
    if fails:
        print('✗ verify 失败 %d 项：' % len(fails))
        for f in fails:
            print('  - ' + f)
        return 1
    print('✓ verify 通过：uid 集合与 §3 一致、DN 合规、uidNumber 唯一、memberUid 无悬空、旧 uid 已归零')
    return 0


def rollback_ldif():
    """生成把线上目录改回旧 uid/DN 的 LDIF（modrdn + 属性回写 + 组关系回写）。"""
    print('# #85 回滚 LDIF —— 把 uid=<new> 改回 cn=<旧显示名>，并恢复 memberUid')
    print('# 用法：docker compose exec -T ldap ldapmodify -x -D cn=admin,dc=devops,dc=com -w "$LDAP_ADMIN_PASSWORD" < rollback.ldif')
    print()
    for blk in parse_entries(read(USERS)):
        uid = next((l[5:].strip() for l in blk if l.startswith('uid: ')), None)
        if not uid:
            continue
        old = next((k for k, v in MAPPING.items() if v[0] == uid and k != uid), None)
        if not old:
            continue
        old_cn = next((l[4:].strip() for l in blk if l.startswith('cn: ')), old)
        print('dn: uid=%s,ou=users,dc=devops,dc=com' % uid)
        print('changetype: modrdn')
        print('newrdn: cn=%s' % old_cn)
        print('deleteoldrdn: 1')
        print()
        print('dn: cn=%s,ou=users,dc=devops,dc=com' % old_cn)
        print('changetype: modify')
        print('replace: uid')
        print('uid: %s' % old)
        print('-')
        print('replace: mail')
        print('mail: %s@devops.com' % old)
        print('-')
        print('replace: homedirectory')
        print('homedirectory: /home/users/%s' % old)
        print('-')
        print('replace: cn')
        print('cn: %s' % old_cn)
        print()
    # 组关系回滚
    print('# ---- 组关系回滚 ----')
    for blk in parse_entries(read(GROUPS)):
        refs = [l.split(':', 1)[1].strip() for l in blk if l.startswith('memberuid: ')]
        newrefs = [r for r in refs if r in set(v[0] for v in MAPPING.values()) and r not in MAPPING]
        if not newrefs:
            continue
        dn = next((l[4:].strip() for l in blk if l.startswith('dn: ')), '')
        print('dn: %s' % dn)
        print('changetype: modify')
        for r in newrefs:
            old = next((k for k, v in MAPPING.items() if v[0] == r), None)
            print('delete: memberUid')
            print('memberUid: %s' % r)
            print('-')
            print('add: memberUid')
            print('memberUid: %s' % old)
            print('-')
        print()


def main():
    args = sys.argv[1:]
    if not args or args[0] in ('-h', '--help'):
        print(__doc__)
        return 0
    mode = args[0]
    if mode == '--check':
        pending = report_state()
        return 0 if pending else 0
    if mode == '--apply':
        apply()
        return 0
    if mode == '--rollback-ldif':
        rollback_ldif()
        return 0
    if mode == '--verify':
        return verify()
    print('未知参数: %s' % mode)
    return 2


if __name__ == '__main__':
    sys.exit(main())
