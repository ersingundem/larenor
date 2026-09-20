"""Policy tests for fail-open Server CI scoping."""

from pathlib import Path
import subprocess
import sys
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tool"))

from server_ci_scope import decide_scope, git_changed_files, is_server_relevant


class ServerCiScopeTest(unittest.TestCase):
    def test_native_characterization_policy_only_changes_reuse_server_evidence(self):
        paths = (
            ".github/workflows/arr-managed-characterization.yml",
            ".github/workflows/jellyfin-managed-characterization.yml",
            ".github/workflows/music-assistant-managed-characterization.yml",
            ".github/workflows/qbittorrent-managed-characterization.yml",
            ".github/workflows/seerr-managed-characterization.yml",
            ".github/workflows/unified-media-stack-managed.yml",
            "tool/native_ci_scope.py",
            "tool/tests/native_ci_scope_test.py",
        )

        for path in paths:
            with self.subTest(path=path):
                self.assertFalse(is_server_relevant(path))
        self.assertEqual(
            decide_scope(
                event_name="pull_request",
                base_sha="a" * 40,
                head_sha="b" * 40,
                changed_files=lambda *_args: paths,
            ),
            (False, "server-inputs-unchanged"),
        )

    def test_flutter_ui_and_documentation_only_changes_reuse_server_evidence(self):
        for paths in (
            ("lib/features/home/home_screen.dart", "test/features/home_test.dart"),
            ("android/app/src/main/AndroidManifest.xml", "assets/icon/app.png"),
            ("integration_test/app_test.dart", "pubspec.lock", "l10n.yaml"),
            ("docs/PROGRESS.md", "README.md", "LICENSE"),
        ):
            with self.subTest(paths=paths):
                self.assertEqual(
                    decide_scope(
                        event_name="pull_request",
                        base_sha="a" * 40,
                        head_sha="b" * 40,
                        changed_files=lambda *_args, value=paths: value,
                    ),
                    (False, "server-inputs-unchanged"),
                )

    def test_server_workflow_sharding_lock_and_unknown_inputs_run(self):
        for path in (
            "server/larenor_server/app.py",
            "server/tests/test_app.py",
            "server/pyproject.toml",
            "server/uv.lock",
            ".github/workflows/server-test.yml",
            ".github/workflows/android-build.yml",
            ".github/workflows/server-build.yml",
            "tool/server_ci_scope.py",
            "tool/server_test_shards.py",
            "tool/server_test_durations.json",
            "contracts/openapi.json",
            "deploy/larenor-server/compose.yaml",
            ".gitignore",
        ):
            with self.subTest(path=path):
                self.assertTrue(is_server_relevant(path))
                self.assertEqual(
                    decide_scope(
                        event_name="pull_request",
                        base_sha="a" * 40,
                        head_sha="b" * 40,
                        changed_files=lambda *_args, value=path: (value,),
                    ),
                    (True, "server-input-changed"),
                )

    def test_non_pr_missing_invalid_empty_and_diff_errors_fail_open(self):
        cases = (
            ("push", "a" * 40, "b" * 40, (), "non-pull-request"),
            ("workflow_dispatch", "", "", (), "non-pull-request"),
            ("pull_request", "", "b" * 40, (), "missing-pull-request-revision"),
            ("pull_request", "bad", "b" * 40, (), "invalid-pull-request-revision"),
            ("pull_request", "a" * 40, "b" * 40, (), "diff-empty"),
        )
        for event, base, head, paths, reason in cases:
            with self.subTest(reason=reason):
                self.assertEqual(
                    decide_scope(
                        event_name=event,
                        base_sha=base,
                        head_sha=head,
                        changed_files=lambda *_args, value=paths: value,
                    ),
                    (True, reason),
                )

        for error in (
            OSError("git unavailable"),
            UnicodeError("invalid path"),
            subprocess.CalledProcessError(128, ["git", "diff"]),
        ):
            with self.subTest(error=type(error).__name__):
                def unavailable(*_args, value=error):
                    raise value

                self.assertEqual(
                    decide_scope(
                        event_name="pull_request",
                        base_sha="a" * 40,
                        head_sha="b" * 40,
                        changed_files=unavailable,
                    ),
                    (True, "diff-unavailable"),
                )

    def test_unsafe_paths_fail_open(self):
        for path in ("", "/absolute", "../escape", "docs/ok.md\nserver/app.py"):
            with self.subTest(path=path):
                self.assertTrue(is_server_relevant(path))

    def test_git_diff_uses_the_exact_revision_pair_and_nul_paths(self):
        completed = subprocess.CompletedProcess(
            [], 0, stdout=b"lib/main.dart\0docs/PROGRESS.md\0"
        )
        with mock.patch("server_ci_scope.subprocess.run", return_value=completed) as run:
            self.assertEqual(
                git_changed_files("a" * 40, "b" * 40),
                ("lib/main.dart", "docs/PROGRESS.md"),
            )
        run.assert_called_once_with(
            [
                "git",
                "diff",
                "--name-only",
                "-z",
                "--no-renames",
                "a" * 40,
                "b" * 40,
                "--",
            ],
            check=True,
            capture_output=True,
        )

        for raw in (b"unterminated", b"bad-utf8-\xff\0"):
            with self.subTest(raw=raw), mock.patch(
                "server_ci_scope.subprocess.run",
                return_value=subprocess.CompletedProcess([], 0, stdout=raw),
            ):
                with self.assertRaises(UnicodeError):
                    git_changed_files("a" * 40, "b" * 40)

    def test_required_check_names_remain_and_every_expensive_step_is_gated(self):
        text = (ROOT / ".github/workflows/server-test.yml").read_text()
        self.assertIn("name: server-test-shard-${{ matrix.shard }}", text)
        self.assertIn("  server-test:\n    name: server-test", text)
        self.assertIn("fetch-depth: 0", text)
        self.assertIn("id: server_scope", text)
        self.assertIn("python3 tool/server_ci_scope.py", text)
        self.assertIn("PR_BASE_SHA: ${{ github.event.pull_request.base.sha }}", text)
        self.assertIn("PR_HEAD_SHA: ${{ github.event.pull_request.head.sha }}", text)

        condition = "steps.server_scope.outputs.run == 'true'"
        expensive_markers = (
            "Select isolated Server test paths",
            "actions/setup-java@",
            "Fetch and verify the pinned Android APK signature library",
            "Prepare isolated pinned Python tooling",
            "Install the reviewed Server dependency lock",
            "Check installed dependency consistency",
            "Exercise authentication, authorization, encrypted storage and API contracts",
            "Preserve synthetic test evidence",
            "Report unavailable Server test artifact",
        )
        shard = text[text.index("  server-test-shard:"):text.index("  server-test:\n")]
        blocks = shard.split("\n      - ")[1:]
        for marker in expensive_markers:
            with self.subTest(marker=marker):
                matching = [block for block in blocks if marker in block]
                self.assertEqual(len(matching), 1)
                block = matching[0]
                self.assertIn(condition, block)


if __name__ == "__main__":
    unittest.main()
