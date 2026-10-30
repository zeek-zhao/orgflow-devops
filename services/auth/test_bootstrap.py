import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).with_name("bootstrap-ldif.sh")


class BootstrapTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        directory = Path(self.directory.name)
        self.log = directory / "commands"
        self.env = dict(
            os.environ, PATH=f"{directory}:{os.environ['PATH']}",
            LDAP_ADMIN_PASSWORD="test-password-not-for-logging", LDAP_TEST_LOG=str(self.log),
            LDAP_URI="ldap://test:389", LDAP_BASE_DN="dc=devops,dc=com",
            LDAP_ADMIN_DN="cn=admin,dc=devops,dc=com",
        )
        client = f"""#!{sys.executable}
import os
from pathlib import Path
import sys

args = sys.argv[1:]
tool = Path(sys.argv[0]).name
with open(os.environ["LDAP_TEST_LOG"], "a") as log:
    log.write(tool + " " + " ".join(args) + "\\n")
if tool == "ldapadd":
    name = Path(args[args.index("-f") + 1]).stem.upper()
    status = int(os.environ.get("LDAP_TEST_" + name, "0"))
else:
    status = int(os.environ.get("LDAP_TEST_SEARCH", "0"))
    if not status:
        print("dn: dc=devops,dc=com")
        if args[args.index("-s") + 1] == "sub":
            print("dn: ou=users,dc=devops,dc=com")
if status:
    print("LDAP test diagnostic: " + str(status), file=sys.stderr)
sys.exit(status)
"""
        for name in ("ldapadd", "ldapsearch"):
            path = directory / name
            path.write_text(client)
            path.chmod(0o755)

    def run_bootstrap(self, *args, **env):
        return subprocess.run(
            ["bash", str(SCRIPT), *args], env=dict(self.env, **env),
            capture_output=True, text=True, timeout=10,
        )

    def test_import_order_count_and_password_cleanup(self):
        result = self.run_bootstrap()
        self.assertEqual(result.returncode, 0, result.stderr)
        commands = self.log.read_text().splitlines()
        imports = [line for line in commands if line.startswith("ldapadd ")]
        self.assertEqual(len(imports), 3)
        for command, name in zip(imports, ("users", "departments", "app")):
            self.assertTrue(command.endswith(f"/ldif/{name}.ldif"))
            self.assertIn(" -c ", command)
        self.assertTrue(result.stdout.endswith("2\n"))
        password_file = commands[0].split(" -y ", 1)[1].split(" ", 1)[0]
        self.assertFalse(Path(password_file).exists())
        self.assertNotIn(self.env["LDAP_ADMIN_PASSWORD"], result.stdout + result.stderr)

    def test_existing_entries_are_nonfatal(self):
        result = self.run_bootstrap(
            LDAP_TEST_USERS="68", LDAP_TEST_DEPARTMENTS="68", LDAP_TEST_APP="68",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(result.stdout.endswith("2\n"))

    def test_entry_failure_reports_warning_and_continues(self):
        result = self.run_bootstrap(LDAP_TEST_DEPARTMENTS="32")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("LDAP test diagnostic: 32", result.stderr)
        self.assertIn("WARNING: entry errors in departments.ldif", result.stderr)
        self.assertIn("/ldif/app.ldif", self.log.read_text())

    def test_connection_or_bind_failure_aborts(self):
        for status in ("81", "255", "49"):
            with self.subTest(status=status):
                result = self.run_bootstrap(LDAP_TEST_USERS=status)
                self.assertEqual(result.returncode, int(status))
                self.assertNotIn("[bootstrap] departments.ldif", result.stdout)
                self.assertIn("aborting", result.stderr)

    def test_failed_preflight_does_not_import(self):
        result = self.run_bootstrap(LDAP_TEST_SEARCH="255")
        self.assertEqual(result.returncode, 255)
        self.assertNotIn("ldapadd ", self.log.read_text())

    def test_dry_run_never_executes_clients_or_requires_password(self):
        result = self.run_bootstrap("--dry-run", LDAP_ADMIN_PASSWORD="")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.log.exists())
        self.assertEqual(result.stdout.count("ldapadd "), 3)
        self.assertIn("grep -c '^dn:'", result.stdout)


if __name__ == "__main__":
    unittest.main()
