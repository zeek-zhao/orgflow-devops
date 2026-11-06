#!/usr/bin/env python3
"""check_nexus_archive.py 的单元测试（#93 / REQ-M0-B5）。

判据的核心是「只备一半必须红」，所以每个用例都是围绕「缺 db」「缺 blobs」
「有 blobs 但没 metadata」「db 零字节」构造合成归档。不依赖 docker。
"""

import io
import json
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
CHECK = ROOT / 'scripts' / 'check_nexus_archive.py'

DB = 'db/nexus.mv.db'
BLOB_META = 'blobs/default/metadata.properties'
BLOB_CONTENT = 'blobs/default/content/directpath/ab/cd/abcdef.bin'


def make_archive(path, files, empty_dirs=()):
    """files: {成员名: bytes}；成员名统一带 ``./`` 前缀，模拟 docker tar 输出。"""
    with tarfile.open(path, 'w:gz') as tar:
        for name in empty_dirs:
            info = tarfile.TarInfo('./' + name)
            info.type = tarfile.DIRTYPE
            info.mode = 0o755
            tar.addfile(info)
        for name, data in files.items():
            info = tarfile.TarInfo('./' + name)
            info.size = len(data)
            tar.addfile(info, io.BytesIO(data))


def full_set():
    return {DB: b'H2' * 500,
            BLOB_META: b'blobStoreName=default\n',
            BLOB_CONTENT: b'\x00\x01binary' * 100}


class NexusArchiveTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)

    def run_check(self, archive, *extra):
        proc = subprocess.run([sys.executable, str(CHECK), str(archive)] + list(extra),
                              capture_output=True, text=True, encoding='utf-8')
        return proc.returncode, (proc.stdout or '') + (proc.stderr or '')

    def archive(self, files, empty_dirs=(), name='nexus-test.tgz'):
        path = self.root / name
        make_archive(path, files, empty_dirs)
        return path

    # --- 通过 ---

    def test_db_and_blobs_pass(self):
        code, out = self.run_check(self.archive(full_set()))
        self.assertEqual(code, 0, out)
        self.assertIn('校验通过', out)
        self.assertIn(DB, out)

    def test_multi_blob_store_pass(self):
        files = full_set()
        files['blobs/backup/metadata.properties'] = b'blobStoreName=backup\n'
        files['blobs/backup/content/x.bin'] = b'x' * 64
        code, out = self.run_check(self.archive(files))
        self.assertEqual(code, 0, out)

    def test_json_output(self):
        code, out = self.run_check(self.archive(full_set()), '--json')
        self.assertEqual(code, 0, out)
        payload = json.loads(out)
        self.assertTrue(payload['ok'])
        self.assertEqual(payload['db']['path'], DB)
        self.assertEqual(len(payload['blob_stores']), 1)
        self.assertGreater(payload['blob_bytes'], 0)

    # --- 反证：只备一半 ---

    def test_only_database_is_red(self):
        files = {DB: b'H2' * 500}
        code, out = self.run_check(self.archive(files))
        self.assertEqual(code, 1, out)
        self.assertIn('blob store', out)
        self.assertIn('校验不通过', out)

    def test_only_blobs_is_red(self):
        files = {BLOB_META: b'blobStoreName=default\n', BLOB_CONTENT: b'\x00' * 32}
        code, out = self.run_check(self.archive(files))
        self.assertEqual(code, 1, out)
        self.assertIn(DB, out)

    def test_blob_dir_without_files_is_red(self):
        # 只有空目录：tar 里能看到 blobs/default/，但没有 metadata.properties。
        code, out = self.run_check(self.archive({DB: b'H2' * 10},
                                                empty_dirs=('blobs/default',)))
        self.assertEqual(code, 1, out)
        self.assertIn('blob store', out)

    def test_blob_content_without_metadata_is_red(self):
        files = {DB: b'H2' * 10, BLOB_CONTENT: b'\x00' * 32}
        code, out = self.run_check(self.archive(files))
        self.assertEqual(code, 1, out)
        self.assertIn('metadata.properties', out)

    def test_zero_byte_database_is_red(self):
        files = full_set()
        files[DB] = b''
        code, out = self.run_check(self.archive(files))
        self.assertEqual(code, 1, out)
        self.assertIn('0 字节', out)

    def test_zero_byte_blobs_is_red(self):
        files = full_set()
        files[BLOB_META] = b''
        files[BLOB_CONTENT] = b''
        code, out = self.run_check(self.archive(files))
        self.assertEqual(code, 1, out)
        self.assertIn('0', out)

    # --- 参数与文件错误 ---

    def test_missing_archive_is_usage_error(self):
        code, out = self.run_check(self.root / 'nope.tgz')
        self.assertEqual(code, 2, out)

    def test_wrong_suffix_is_usage_error(self):
        path = self.root / 'nexus.tar'
        path.write_bytes(b'not a tgz')
        code, out = self.run_check(path)
        self.assertEqual(code, 2, out)

    def test_corrupt_archive_is_red(self):
        path = self.root / 'broken.tgz'
        path.write_bytes(b'this is not gzip')
        code, out = self.run_check(path)
        self.assertEqual(code, 1, out)
        self.assertIn('归档无法读取', out)


if __name__ == '__main__':
    unittest.main(verbosity=2)
