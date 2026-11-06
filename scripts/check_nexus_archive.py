#!/usr/bin/env python3
"""Nexus 备份包内容校验：H2 数据库与 blob store 必须同时存在。

背景（#93 / REQ-M0-B5）
-----------------------
Nexus 的数据分两处，缺一不可：

  * ``db/nexus.mv.db``    H2 MVStore 数据库 —— 仓库定义、组件元数据、安全配置
  * ``blobs/<store>/``    blob store —— 真正的制品字节

只备其中一处得到的包，``sha256`` 对、``tar tzf`` 能解开、恢复脚本也不报错，
但恢复出来是残缺实例（要么有元数据没字节，要么有字节没索引）。这是典型的
**静默失败**，必须由内容级判据拦下，而不是靠人记得。

判据
----
1. 归档里存在 ``db/nexus.mv.db`` 且字节数 > 0；
2. 至少一个 ``blobs/<store>/metadata.properties`` 且字节数 > 0
   （每个 blob store 必有此文件，它证明 blob store 被真正归档，而不是只留了空目录）；
3. ``blobs/`` 下常规文件总字节 > 0。

用法
----
    python3 scripts/check_nexus_archive.py out/backups/nexus-20261106-....tgz
    python3 scripts/check_nexus_archive.py --json <archive>

退出码
------
0 通过 · 1 内容不合规 · 2 参数或文件不可用
"""

import argparse
import json
import os
import sys
import tarfile

DB_MEMBER = 'db/nexus.mv.db'
BLOBS_PREFIX = 'blobs/'
STORE_METADATA_SUFFIX = '/metadata.properties'


def fail_usage(msg):
    print('用法错误: %s' % msg, file=sys.stderr)
    raise SystemExit(2)


def normalize(name):
    """把 ``./db/x`` 归一成 ``db/x``；越界路径返回 None。"""
    if name.startswith('/'):
        return None
    parts = [p for p in name.split('/') if p not in ('', '.')]
    if any(p == '..' for p in parts):
        return None
    return '/'.join(parts)


def scan(archive):
    """读归档，返回 (成员大小表, 失败项, 警告项)。"""
    failures = []
    warnings = []
    sizes = {}

    try:
        with tarfile.open(archive, 'r:gz') as tar:
            for member in tar:
                if not member.isfile():
                    continue
                name = normalize(member.name)
                if name is None:
                    continue
                sizes[name] = member.size
    except (tarfile.TarError, OSError) as exc:
        return None, ['归档无法读取（不是合法 .tgz 或已损坏）: %s' % exc], warnings

    if not sizes:
        failures.append('归档里没有任何常规文件，不是有效的 Nexus 备份')

    db_bytes = sizes.get(DB_MEMBER)
    if db_bytes is None:
        # 后端可能已经换成 PostgreSQL —— 给出可执行的提示而不是只说缺文件。
        h2_like = [n for n in sizes if n.startswith('db/') and n.endswith('.mv.db')]
        if h2_like:
            failures.append(
                '缺少 %s（归档里有其它 H2 文件: %s）' % (DB_MEMBER, ', '.join(sorted(h2_like)[:3])))
        else:
            failures.append(
                '缺少 %s —— 未发现任何 H2 MVStore 文件。'
                '若 Nexus 后端已切到 PostgreSQL，本判据需同步改为 pg_dump 产物' % DB_MEMBER)
    elif db_bytes <= 0:
        failures.append('%s 为 0 字节（数据库导出是空的）' % DB_MEMBER)

    stores = {}
    for name, size in sizes.items():
        if not name.startswith(BLOBS_PREFIX):
            continue
        rest = name[len(BLOBS_PREFIX):]
        if '/' not in rest:
            continue
        store = rest.split('/', 1)[0]
        entry = stores.setdefault(store, {'metadata_bytes': 0, 'files': 0, 'bytes': 0})
        entry['files'] += 1
        entry['bytes'] += size
        if name.endswith(STORE_METADATA_SUFFIX) and rest.count('/') == 1:
            entry['metadata_bytes'] += size

    blob_bytes = sum(s['bytes'] for s in stores.values())
    if not stores:
        failures.append('缺少 blob store 归档（归档里没有任何 blobs/<store>/ 内容）')
    else:
        missing_meta = sorted(n for n, s in stores.items() if s['metadata_bytes'] <= 0)
        if missing_meta:
            failures.append(
                'blob store 缺少 metadata.properties: %s（只归档了目录，blob store 未真正备份）'
                % ', '.join(missing_meta))
        if blob_bytes <= 0:
            failures.append('blob store 文件总字节为 0（制品字节没有归档进来）')

    return {'sizes': sizes, 'db_bytes': db_bytes, 'stores': stores,
            'blob_bytes': blob_bytes}, failures, warnings


def main():
    parser = argparse.ArgumentParser(
        description='校验 Nexus 备份包是否同时包含 H2 数据库与 blob store')
    parser.add_argument('archive', help='Nexus 备份包（.tgz）')
    parser.add_argument('--json', action='store_true', help='输出 JSON 而不是人读文本')
    args = parser.parse_args()

    archive = args.archive
    if not archive.endswith('.tgz'):
        fail_usage('备份包必须是 .tgz: %s' % archive)
    if not os.path.isfile(archive):
        fail_usage('备份包不存在或不是普通文件: %s' % archive)
    if not os.access(archive, os.R_OK):
        fail_usage('备份包不可读: %s' % archive)

    result, failures, warnings = scan(archive)
    ok = result is not None and not failures

    if args.json:
        payload = {
            'archive': archive,
            'ok': ok,
            'db': None,
            'blob_stores': [],
            'blob_bytes': 0,
            'failures': failures,
            'warnings': warnings,
        }
        if result is not None:
            if result['db_bytes'] is not None:
                payload['db'] = {'path': DB_MEMBER, 'bytes': result['db_bytes']}
            payload['blob_bytes'] = result['blob_bytes']
            payload['blob_stores'] = [
                {'name': name, 'files': s['files'], 'bytes': s['bytes'],
                 'metadata_bytes': s['metadata_bytes']}
                for name, s in sorted(result['stores'].items())]
        print(json.dumps(payload, ensure_ascii=False, indent=2))
        raise SystemExit(0 if ok else 1)

    print('== Nexus 备份包内容校验: %s ==' % archive)
    if result is not None:
        db_bytes = result['db_bytes']
        if db_bytes is None:
            print('  %-42s %s' % (DB_MEMBER, '缺失'))
        else:
            print('  %-42s %10d B  %s' % (DB_MEMBER, db_bytes, '✓' if db_bytes > 0 else '✗ 空'))
        for name, store in sorted(result['stores'].items()):
            print('  blob store %-29s %3d 文件 / %10d B  %s'
                  % (name, store['files'], store['bytes'],
                     '✓' if store['metadata_bytes'] > 0 and store['bytes'] > 0 else '✗'))
        print('  %-42s %10d B' % ('blob store 合计', result['blob_bytes']))
        total = (db_bytes or 0) + result['blob_bytes']
        print('  %-42s %10d B' % ('db + blobs 合计', total))

    for msg in warnings:
        print('  ! %s' % msg)
    if failures:
        for msg in failures:
            print('  ✗ %s' % msg)
        print('✗ 校验不通过：数据库与 blob store 必须同时在备份包里')
        raise SystemExit(1)
    print('✓ 校验通过：数据库与 blob store 同时存在且非空')
    raise SystemExit(0)


if __name__ == '__main__':
    main()
