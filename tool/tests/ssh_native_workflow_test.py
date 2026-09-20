import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = ROOT / ".github/workflows/ssh-native-acceptance.yml"


class SshNativeWorkflowPolicyTest(unittest.TestCase):
    def setUp(self):
        self.raw = WORKFLOW.read_text(encoding="utf-8")

    def test_ephemeral_runner_and_openssh_package_are_exact(self):
        self.assertRegex(
            self.raw,
            r"ssh-native-acceptance:\s*\n\s+runs-on: ubuntu-24\.04",
        )
        self.assertIn('OPENSSH_PACKAGE: "1:9.6p1-3ubuntu13.19"', self.raw)
        self.assertIn('"openssh-server=$OPENSSH_PACKAGE"', self.raw)
        self.assertIn("dpkg-query", self.raw)
        self.assertIn("127.0.0.1", self.raw)

    def test_actions_and_flutter_are_immutable(self):
        uses = re.findall(r"uses:\s*([^\s#]+)", self.raw)
        self.assertTrue(uses)
        self.assertTrue(
            all(re.fullmatch(r"[^@]+@[0-9a-f]{40}", value) for value in uses),
            uses,
        )
        self.assertIn('flutter-version: "3.47.2"', self.raw)
        self.assertIn("flutter pub get --enforce-lockfile", self.raw)
        self.assertIn("flutter gen-l10n", self.raw)

    def test_fixture_is_private_bounded_and_runs_exact_native_suite(self):
        self.assertIn("PasswordAuthentication no", self.raw)
        self.assertIn("PermitRootLogin no", self.raw)
        self.assertIn("AllowTcpForwarding local", self.raw)
        self.assertIn("MaxSessions 4", self.raw)
        self.assertIn("MaxStartups 4:30:4", self.raw)
        self.assertIn("ssh_native_fixture_test.dart", self.raw)
        self.assertIn("ssh_terminal_panel_test.dart", self.raw)
        self.assertIn("sftp_browser_panel_test.dart", self.raw)
        self.assertIn("ssh_tunnel_panel_test.dart", self.raw)
        self.assertNotRegex(self.raw, r"\$\{\{\s*secrets\.")
        self.assertNotIn("0.0.0.0", self.raw)


if __name__ == "__main__":
    unittest.main()
