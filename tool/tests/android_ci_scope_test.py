"""Policy tests for fail-open Android/Flutter CI scoping."""

from pathlib import Path
import re
import subprocess
import sys
import unittest


ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'tool'))

from android_ci_scope import decide_scope, is_android_relevant


class AndroidCiScopeTest(unittest.TestCase):
    def test_native_characterization_policy_only_changes_reuse_android_evidence(self):
        paths = (
            '.github/workflows/arr-managed-characterization.yml',
            '.github/workflows/jellyfin-managed-characterization.yml',
            '.github/workflows/music-assistant-managed-characterization.yml',
            '.github/workflows/qbittorrent-managed-characterization.yml',
            '.github/workflows/seerr-managed-characterization.yml',
            '.github/workflows/unified-media-stack-managed.yml',
            'deploy/larenor-server/.env.example',
            'deploy/larenor-server/unified.compose.yaml',
            'deploy/larenor-server/unified_package.py',
            'deploy/larenor-server/deployment_bundle.py',
            'tool/native_ci_scope.py',
            'tool/tests/native_ci_scope_test.py',
            'tool/unified_media_stack_managed_ci.py',
            'tool/tests/unified_media_stack_runtime_test.py',
        )

        for path in paths:
            with self.subTest(path=path):
                self.assertFalse(is_android_relevant(path))
        self.assertEqual(decide_scope(
            event_name='pull_request', base_sha='a' * 40,
            head_sha='b' * 40,
            changed_files=lambda *_args: paths,
        ), (False, 'android-inputs-unchanged'))

    def test_server_and_documentation_only_changes_reuse_android_evidence(self):
        for paths in (
            ('server/larenor_server/app.py', 'server/tests/test_app.py'),
            ('docs/PROGRESS.md', 'README.md', 'LICENSE'),
        ):
            with self.subTest(paths=paths):
                self.assertEqual(decide_scope(
                    event_name='pull_request', base_sha='a' * 40,
                    head_sha='b' * 40,
                    changed_files=lambda *_args, value=paths: value,
                ), (False, 'android-inputs-unchanged'))

    def test_progress_policy_only_changes_reuse_android_evidence(self):
        paths = (
            'tool/check_commit_progress.py',
            'tool/commit_with_progress.py',
            'tool/execution_queue.py',
            'tool/tests/check_commit_progress_test.py',
            'tool/tests/commit_with_progress_test.py',
            'tool/tests/execution_queue_test.py',
        )
        for path in paths:
            with self.subTest(path=path):
                self.assertFalse(is_android_relevant(path))
        self.assertEqual(decide_scope(
            event_name='pull_request', base_sha='a' * 40,
            head_sha='b' * 40,
            changed_files=lambda *_args: paths,
        ), (False, 'android-inputs-unchanged'))

    def test_every_android_flutter_workflow_and_build_input_runs(self):
        paths = (
            'lib/main.dart', 'android/app/build.gradle.kts',
            'integration_test/app_test.dart', 'test/widget_test.dart',
            'pubspec.yaml', 'pubspec.lock', 'l10n.yaml',
            'lib/l10n/app_en.arb', '.github/workflows/server-test.yml',
            'tool/android_signing.py', 'tool/prepare_android_e2e_build.sh',
            'build.yaml', 'analysis_options.yaml', 'assets/logo.png',
        )
        for path in paths:
            with self.subTest(path=path):
                self.assertTrue(is_android_relevant(path))
                self.assertEqual(decide_scope(
                    event_name='pull_request', base_sha='a' * 40,
                    head_sha='b' * 40,
                    changed_files=lambda *_args, value=path: (value,),
                ), (True, 'android-input-changed'))

    def test_manual_missing_invalid_empty_and_diff_error_fail_open(self):
        cases = (
            ('workflow_dispatch', 'a' * 40, 'b' * 40, (),
             'non-pull-request'),
            ('pull_request', '', 'b' * 40, (),
             'missing-pull-request-revision'),
            ('pull_request', 'not-a-sha', 'b' * 40, (),
             'invalid-pull-request-revision'),
            ('pull_request', 'a' * 40, 'b' * 40, (), 'diff-empty'),
        )
        for event, base, head, paths, reason in cases:
            with self.subTest(reason=reason):
                self.assertEqual(decide_scope(
                    event_name=event, base_sha=base, head_sha=head,
                    changed_files=lambda *_args, value=paths: value,
                ), (True, reason))

        def unavailable(*_args):
            raise subprocess.CalledProcessError(128, ['git', 'diff'])

        self.assertEqual(decide_scope(
            event_name='pull_request', base_sha='a' * 40,
            head_sha='b' * 40, changed_files=unavailable,
        ), (True, 'diff-unavailable'))

    def test_unknown_or_unsafe_paths_fail_open(self):
        for path in ('scripts/release.sh', '.gitignore', '../escape', '',
                     'docs/ok.md\nlib/injected.dart'):
            with self.subTest(path=path):
                self.assertTrue(is_android_relevant(path))

    def test_required_jobs_keep_names_and_scope_only_expensive_steps(self):
        policies = {
            '.github/workflows/analyze-test.yml': (
                '  analyze-test:', ('subosito/flutter-action@',
                                     'flutter test --coverage')),
            '.github/workflows/android-e2e.yml': (
                '  emulator-journeys:', ('actions/setup-java@',
                                          'ReactiveCircus/android-emulator-runner@')),
            '.github/workflows/android-build.yml': (
                '  build-debug-apk:', ('actions/setup-java@',
                                       'flutter build apk --debug')),
        }
        condition = "steps.android_scope.outputs.run == 'true'"
        for path, (job, markers) in policies.items():
            text = (ROOT / path).read_text()
            with self.subTest(path=path):
                self.assertIn(job, text)
                self.assertIn('id: android_scope', text)
                self.assertIn('python3 tool/android_ci_scope.py', text)
                self.assertIn('fetch-depth: 0', text)
                self.assertIn('PR_BASE_SHA: ${{ github.event.pull_request.base.sha }}', text)
                self.assertIn('PR_HEAD_SHA: ${{ github.event.pull_request.head.sha }}', text)
                self.assertIn('Android/Flutter checks reused', text)
                for marker in markers:
                    block = text[max(0, text.index(marker) - 520):
                                 text.index(marker) + 240]
                    self.assertIn(condition, block)

        security = (ROOT / '.github/workflows/security.yml').read_text()
        self.assertNotIn('android_ci_scope.py', security)
        check = re.search(
            r'- run: python3 tool/check_security_policy\.py(?P<tail>[^\n]*)',
            security)
        self.assertIsNotNone(check)
        self.assertNotIn('if:', check.group('tail'))


if __name__ == '__main__':
    unittest.main()
