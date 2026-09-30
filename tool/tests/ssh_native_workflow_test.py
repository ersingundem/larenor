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
        self.assertIn("actions/setup-java@de7274f081f381c8f8158605e0321c36c376e2e6", self.raw)
        self.assertIn("distribution: temurin", self.raw)
        self.assertIn('java-version: "17"', self.raw)
        self.assertIn("flutter pub get --enforce-lockfile", self.raw)
        self.assertIn("flutter gen-l10n", self.raw)
        self.assertIn(
            "dart run build_runner build --delete-conflicting-outputs",
            self.raw,
        )

    def test_normal_core_gate_installs_exact_uv_before_use(self):
        setup = (
            "uses: astral-sh/setup-uv@"
            "c18668ad3cf93ea998bef934396af7bb5c839dc7 # v10.2.0"
        )
        invocation = (
            "uv run --project server --locked python "
            "server/tests/support/f63_flutter_acceptance.py"
        )
        self.assertIn(setup, self.raw)
        self.assertIn('version: "0.12.12"', self.raw)
        self.assertIn('python-version: "3.12"', self.raw)
        self.assertIn("enable-cache: false", self.raw)
        self.assertLess(self.raw.index(setup), self.raw.index(invocation))

    def test_real_fixture_uses_strict_machine_report_before_regressions(self):
        strict = "python3 tool/f63_openssh_acceptance.py"
        regressions = "test/features/remote_access/ssh/ssh_session_controller_test.dart"
        self.assertIn(strict, self.raw)
        self.assertIn("tool.tests.f63_openssh_acceptance_test", self.raw)
        self.assertLess(self.raw.index(strict), self.raw.index(regressions))
        self.assertNotIn(
            "test/features/remote_access/ssh/ssh_native_fixture_test.dart \\",
            self.raw,
        )

    def test_only_nonsecret_native_receipt_is_uploaded(self):
        upload = (
            "uses: actions/upload-artifact@"
            "043fb46d1a93c77aae656e7c1c64a875d1fc6a0a # v4"
        )
        receipt = "path: build/f63-openssh-acceptance/receipt.json"
        self.assertEqual(self.raw.count(upload), 1)
        self.assertIn('name: "f63-openssh-${{ github.sha }}"', self.raw)
        self.assertIn(receipt, self.raw)
        self.assertIn("if-no-files-found: error", self.raw)
        self.assertNotIn("native-events.json", self.raw)
        self.assertLess(
            self.raw.index("python3 tool/f63_openssh_acceptance.py"),
            self.raw.index(upload),
        )
        self.assertLess(
            self.raw.index(receipt),
            self.raw.index("test/features/remote_access/ssh/ssh_session_controller_test.dart"),
        )

    def test_fixture_is_private_bounded_and_runs_exact_native_suite(self):
        self.assertIn('fixture_user="larenor-fixture"', self.raw)
        self.assertIn(
            'sudo useradd --create-home --shell /bin/bash "$fixture_user"',
            self.raw,
        )
        self.assertIn('sudo chpasswd', self.raw)
        self.assertIn('runner_group="$(id -gn)"', self.raw)
        self.assertIn(
            'sftp_root="/tmp/larenor-ssh-native-sftp-${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}"',
            self.raw,
        )
        self.assertIn(
            'sudo install -d -m 0770 -o "$fixture_user" -g "$runner_group" "$sftp_root"',
            self.raw,
        )
        self.assertIn("LARENOR_SFTP_FIXTURE_ROOT=$sftp_root", self.raw)
        self.assertIn(
            '[[ "$sftp_root" == /tmp/larenor-ssh-native-sftp-* ]]',
            self.raw,
        )
        self.assertIn('sudo rm -rf -- "$sftp_root"', self.raw)
        self.assertNotIn("LARENOR_SFTP_FIXTURE_ROOT=$fixture/sftp", self.raw)
        self.assertNotIn('passwd -d "$USER"', self.raw)
        self.assertIn("AuthenticationMethods publickey password", self.raw)
        self.assertIn("AuthenticationMethods password", self.raw)
        self.assertIn(
            "AuthenticationMethods publickey,keyboard-interactive:pam",
            self.raw,
        )
        self.assertIn("KbdInteractiveAuthentication yes", self.raw)
        self.assertIn("UsePAM yes", self.raw)
        self.assertIn("LARENOR_SSH_JUMP_HOST_KEY_FINGERPRINT", self.raw)
        self.assertIn("LARENOR_SSH_MFA_HOST_KEY_FINGERPRINT", self.raw)
        self.assertIn("PermitRootLogin no", self.raw)
        self.assertIn("AllowTcpForwarding local", self.raw)
        self.assertIn("MaxSessions 4", self.raw)
        self.assertIn("MaxStartups 4:30:4", self.raw)
        self.assertIn("ssh_native_fixture_test.dart", self.raw)
        self.assertIn("ssh_terminal_panel_test.dart", self.raw)
        self.assertIn("sftp_browser_panel_test.dart", self.raw)
        self.assertIn("ssh_tunnel_panel_test.dart", self.raw)
        self.assertIn("f63_flutter_acceptance.py", self.raw)
        self.assertIn("LARENOR_F63_COMMAND_LOG", self.raw)
        self.assertNotRegex(self.raw, r"\$\{\{\s*secrets\.")
        self.assertNotIn("0.0.0.0", self.raw)

    def test_failure_diagnostics_can_read_root_owned_sshd_log(self):
        self.assertIn('sudo tail -80 "$fixture/sshd.log"', self.raw)

    def test_android_host_contract_is_built_and_inspected(self):
        self.assertIn("flutter build apk --debug --target-platform android-arm64 --no-pub", self.raw)
        self.assertIn("app-debug.apk", self.raw)
        self.assertIn("dump permissions", self.raw)
        self.assertIn("android.permission.INTERNET", self.raw)
        self.assertIn("lib/arm64-v8a/libflutter.so", self.raw)
        self.assertIn("Unexpected SSH JNI library", self.raw)


if __name__ == "__main__":
    unittest.main()
