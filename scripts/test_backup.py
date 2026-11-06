import hashlib
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


class BackupTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.backups = self.root / "backups"
        self.backups.mkdir()
        self.volume = self.root / "volume"
        self.volume.mkdir()
        (self.volume / ".hidden").write_text("restore me\n")
        (self.volume / "directory").mkdir()
        (self.volume / "directory/data").write_text("test data\n")
        self.running = self.root / "running"
        self.running.touch()
        self.log = self.root / "calls.jsonl"
        bin_dir = self.root / "bin"
        bin_dir.mkdir()
        self.env = {
            key: value for key, value in os.environ.items()
            if key not in ("BACKUP_DIR", "BACKUP_TARGET", "BACKUP_RETENTION_DAYS",
                           "RETENTION", "COMPOSE", "ENV_FILE")
        }
        self.env.update(
            PATH=f"{bin_dir}:{os.environ['PATH']}", BACKUP_DIR=str(self.backups),
            FAKE_ROOT=str(self.root),
        )
        docker = bin_dir / "docker"
        docker.write_text(f"""#!{sys.executable}
import io
import json
import os
from pathlib import Path
import shutil
import sys
import tarfile

root = Path(os.environ["FAKE_ROOT"])
args = sys.argv[1:]
with (root / "calls.jsonl").open("a") as log:
    log.write(json.dumps(args) + "\\n")
running = root / "running"
volume = root / "volume"
if args[:2] == ["volume", "inspect"]:
    sys.exit(1 if os.environ.get("FAKE_MISSING_VOLUME") else 0)
if args[0] == "compose":
    if "ps" in args:
        if os.environ.get("FAKE_PS_FAIL") or (os.environ.get("FAKE_PS_FAIL_AFTER_STOP") and not running.exists()):
            sys.exit(23)
        if "-a" in args or running.exists():
            print("container-id")
    elif "stop" in args:
        if os.environ.get("FAKE_STOP_FAIL"):
            sys.exit(23)
        if not os.environ.get("FAKE_STOP_IGNORED"):
            running.unlink(missing_ok=True)
    elif "start" in args:
        if os.environ.get("FAKE_START_FAIL"):
            sys.exit(23)
        running.touch()
elif args[0] == "run":
    if "tar" in args:
        if os.environ.get("FAKE_ARCHIVE_FAIL") or os.environ.get("FAKE_CORRUPT"):
            sys.stdout.buffer.write(b"broken archive")
            sys.exit(23 if os.environ.get("FAKE_ARCHIVE_FAIL") else 0)
        with tarfile.open(fileobj=sys.stdout.buffer, mode="w|gz") as archive:
            archive.add(volume, arcname=".")
    elif "tar xzpf" in args[-1]:
        if running.exists():
            sys.exit("refusing extraction while running")
        for path in volume.iterdir():
            if path.is_dir() and not path.is_symlink():
                shutil.rmtree(path)
            else:
                path.unlink()
        if os.environ.get("FAKE_EXTRACT_FAIL"):
            sys.exit(23)
        with tarfile.open(fileobj=io.BytesIO(sys.stdin.buffer.read()), mode="r:gz") as archive:
            archive.extractall(volume, filter="data")
    else:
        print(len(list(volume.rglob("*"))))
else:
    sys.exit("unexpected fake Docker command")
""")
        docker.chmod(0o755)
        # Age even the newly published package to prove retention uses a whitelist,
        # not merely the normal freshly-written mtime.
        mv = bin_dir / "mv"
        mv.write_text(f"""#!{sys.executable}
import os
import subprocess
import sys
status = subprocess.call([{shutil.which("mv")!r}, *sys.argv[1:]])
if status == 0 and os.environ.get("FAKE_OLD_NEW") and sys.argv[-1].endswith(".tgz"):
    os.utime(sys.argv[-1], (0, 0))
sys.exit(status)
""")
        mv.chmod(0o755)

    def run_script(self, script, *args, **env):
        return subprocess.run(
            ["bash", str(ROOT / "scripts" / f"{script}.sh"), *args],
            cwd=self.root, env=dict(self.env, **env),
            capture_output=True, text=True, timeout=15,
        )

    def backup(self, **env):
        previous = set(self.backups.glob("ldap-*.tgz"))
        result = self.run_script("backup", "--service", "ldap", **env)
        self.assertEqual(result.returncode, 0, result.stderr)
        created = set(self.backups.glob("ldap-*.tgz")) - previous
        self.assertEqual(len(created), 1)
        return created.pop()

    def calls(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()] if self.log.exists() else []

    def old_package(self, service="ldap"):
        path = self.backups / f"{service}-old.tgz"
        for suffix in (".tgz", ".sha256", ".meta"):
            part = path.with_suffix(suffix)
            part.write_text("expired")
            os.utime(part, (0, 0))
        return path

    def test_invalid_backup_parameters_before_docker(self):
        for args, env, message in (
            (["--service", "unknown"], {}, "未知服务"),
            (["--unknown"], {}, "未知参数"),
            (["--service"], {}, "需要指定参数"),
            (["--all", "--service", "ldap"], {}, "不能重复或同用"),
            (["--all"], {"RETENTION": "abc"}, "整数"),
            (["--all"], {"BACKUP_RETENTION_DAYS": "-1"}, "整数"),
            (["--all"], {"BACKUP_TARGET": "remote"}, "仅支持"),
        ):
            with self.subTest(args=args, env=env):
                result = self.run_script("backup", *args, **env)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(message, result.stderr)
                self.assertFalse(self.log.exists())

    def test_zero_refuses_cleanup_but_keeps_backup(self):
        old = self.old_package()
        result = self.run_script("backup", "--service", "ldap", RETENTION="0")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("拒绝清理", result.stderr)
        self.assertTrue(old.exists())
        self.assertEqual(len(list(self.backups.glob("*.tgz"))), 2)

    def test_retention_excludes_current_even_with_expired_mtime(self):
        old = self.old_package()
        other = self.old_package("jenkins")
        new = self.backup(BACKUP_RETENTION_DAYS="1", FAKE_OLD_NEW="1")
        self.assertEqual(new.stat().st_mtime, 0)
        for suffix in (".tgz", ".sha256", ".meta"):
            self.assertFalse(old.with_suffix(suffix).exists())
            self.assertTrue(new.with_suffix(suffix).exists())
            self.assertTrue(other.with_suffix(suffix).exists())

    def test_metadata_checksum_and_stop_start_order(self):
        archive = self.backup()
        meta = dict(line.split("=", 1) for line in archive.with_suffix(".meta").read_text().splitlines())
        self.assertEqual(meta["service"], "ldap")
        self.assertEqual(meta["volume"], "orgflow-devops_ldap_data")
        self.assertEqual(int(meta["bytes"]), archive.stat().st_size)
        with tarfile.open(archive) as handle:
            self.assertEqual(int(meta["files"]), len(handle.getmembers()))
        self.assertEqual(meta["retention_days"], "7")
        self.assertRegex(meta["created_at"], r"^\d{4}-\d\d-\d\dT.*Z$")
        self.assertEqual(archive.with_suffix(".sha256").read_text(),
                         f"{hashlib.sha256(archive.read_bytes()).hexdigest()}  {archive.name}\n")
        calls = self.calls()
        stop = next(i for i, call in enumerate(calls) if "stop" in call)
        run = next(i for i, call in enumerate(calls) if call[0] == "run")
        start = next(i for i, call in enumerate(calls) if "start" in call)
        self.assertLess(stop, run)
        self.assertLess(run, start)
        self.assertTrue(self.running.exists())
        self.log.unlink()
        result = self.run_script("backup", "--verify", str(archive))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.log.exists())

    def test_failed_or_corrupt_archive_removed_and_service_restarted(self):
        for env in ({"FAKE_ARCHIVE_FAIL": "1"}, {"FAKE_CORRUPT": "1"}):
            with self.subTest(env=env):
                old = self.old_package()
                result = self.run_script("backup", "--service", "ldap", **env)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(list(self.backups.glob("*.tgz")), [old])
                self.assertFalse(list(self.backups.glob(".ldap-*.*/")))
                self.assertTrue(self.running.exists())

    def test_stop_failure_never_archives(self):
        for env in ({"FAKE_STOP_FAIL": "1"}, {"FAKE_STOP_IGNORED": "1"},
                    {"FAKE_PS_FAIL": "1"}, {"FAKE_PS_FAIL_AFTER_STOP": "1"}):
            with self.subTest(env=env):
                self.log.unlink(missing_ok=True)
                result = self.run_script("backup", "--service", "ldap", **env)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(any(call[0] == "run" for call in self.calls()))

    def test_no_stop_escape_and_previously_stopped_service(self):
        result = self.run_script("backup", "--service", "ldap", "--no-stop")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("可能不一致", result.stderr)
        self.assertFalse(any("stop" in call or "start" in call for call in self.calls()))
        self.log.unlink()
        self.running.unlink()
        self.backup()
        self.assertFalse(self.running.exists())
        self.assertFalse(any("start" in call for call in self.calls()))

    def seed_nexus_volume(self):
        """把假卷造成 Nexus 的真实形状：db/ 与 blobs/ 两处（#93 内容级门禁要求）。

        backup.sh 对 nexus 包会跑 check_nexus_archive.py，只含 .hidden 与
        directory/ 的通用假卷会被判「缺 H2 数据库与 blob store」——这正是门禁
        应有的行为；所以这里按真实卷补上两类文件，让 --all 走绿路径。
        「只备 db」的红路径由 test_jobs.py 的 JOB_TEST_NEXUS_DB_ONLY 与
        test_nexus_archive.py 覆盖。
        """
        (self.volume / "db").mkdir(exist_ok=True)
        (self.volume / "db/nexus.mv.db").write_bytes(b"H2" * 64)
        (self.volume / "blobs/default/content").mkdir(parents=True, exist_ok=True)
        (self.volume / "blobs/default/metadata.properties").write_bytes(
            b"blobStoreName=default\n")
        (self.volume / "blobs/default/content/x.bin").write_bytes(b"\x00\x01" * 32)

    def test_all_volume_mappings(self):
        self.seed_nexus_volume()
        result = self.run_script("backup", "--all")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(list(self.backups.glob("*.tgz"))), 3)
        for service, volume in (("jenkins", "jenkins_home"), ("nexus", "nexus_data"), ("ldap", "ldap_data")):
            self.assertIn(["volume", "inspect", f"orgflow-devops_{volume}"], self.calls())

    def test_verify_corrupt_or_checksum_mismatch(self):
        archive = self.backup()
        archive.with_suffix(".sha256").unlink()
        archive.write_bytes(b"bad tar")
        result = self.run_script("backup", "--verify", str(archive))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("tar 校验失败", result.stderr)
        archive = self.backup()
        archive.write_bytes(archive.read_bytes() + b"tampered")
        result = self.run_script("backup", "--verify", str(archive))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("sha256 校验失败", result.stderr)

    def test_restore_refuses_nonempty_and_dry_run_changes_nothing(self):
        archive = self.backup()
        self.log.unlink()
        result = self.run_script("restore", "--service", "ldap", "--file", str(archive))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("现有条目数: 3", result.stderr)
        self.assertIn("--force", result.stderr)
        result = self.run_script("restore", "--service", "ldap", "--file", str(archive), "--force", "--dry-run")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("dry-run", result.stdout)
        self.assertTrue(self.running.exists())
        self.assertEqual((self.volume / ".hidden").read_text(), "restore me\n")
        self.assertFalse(any("stop" in call or "start" in call for call in self.calls()))
        self.assertTrue(all("/data:ro" in call[call.index("-v") + 1]
                            for call in self.calls() if call[0] == "run"))

    def test_restore_replaces_contents_and_preserves_hidden_files(self):
        archive = self.backup()
        (self.volume / "extra").write_text("remove me")
        result = self.run_script("restore", "--service", "ldap", "--file", str(archive), "--force")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((self.volume / "extra").exists())
        self.assertEqual((self.volume / ".hidden").read_text(), "restore me\n")
        self.assertTrue(self.running.exists())
        self.assertFalse(any(call[:2] == ["volume", "rm"] for call in self.calls()))

    def test_extract_failure_keeps_service_stopped(self):
        archive = self.backup()
        result = self.run_script("restore", "--service", "ldap", "--file", str(archive),
                                 "--force", FAKE_EXTRACT_FAIL="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("保持停止", result.stderr)
        self.assertFalse(self.running.exists())

    def test_restore_external_archive_and_missing_manifest_warning(self):
        archive = self.backup()
        external = self.root / "external.tgz"
        shutil.copyfile(archive, external)
        result = self.run_script("restore", "--service", "ldap", "--file", str(external), "--force", "--dry-run")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("缺少 sha256", result.stderr)
        external.write_bytes(b"corrupt")
        result = self.run_script("restore", "--service", "ldap", "--file", str(external), "--force")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("tar 校验失败", result.stderr)

    def test_restore_invalid_inputs_do_not_touch_docker(self):
        fifo = self.root / "pipe.tgz"
        os.mkfifo(fifo)
        for args, message in (
            (["--service", "other", "--file", "missing.tgz"], "未知服务"),
            (["--unknown"], "未知参数"),
            (["--service", "ldap"], "--file 必填"),
            (["--service", "ldap", "--file", "missing.tgz"], "普通文件"),
            (["--service", "ldap", "--file", str(self.backups)], "普通文件"),
            (["--service", "ldap", "--file", str(fifo)], "普通文件"),
        ):
            with self.subTest(args=args):
                result = self.run_script("restore", *args)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(message, result.stderr)
                self.assertFalse(self.log.exists())

    def test_wrong_service_metadata_and_unsafe_tar_refused(self):
        archive = self.backup()
        self.log.unlink()
        result = self.run_script("restore", "--service", "jenkins", "--file", str(archive), "--force")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("不匹配", result.stderr)
        unsafe = self.root / "unsafe.tgz"
        with tarfile.open(unsafe, "w:gz") as handle:
            member = tarfile.TarInfo("../escape")
            member.size = 3
            handle.addfile(member, io.BytesIO(b"bad"))
        result = self.run_script("restore", "--service", "ldap", "--file", str(unsafe), "--force")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("不安全", result.stderr)
        self.assertFalse(self.log.exists())


if __name__ == "__main__":
    unittest.main()
