"""Required CI check names and permissions must survive cancellation repair."""

import json
import os
import shutil
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
WORKFLOWS = ROOT / ".github/workflows"
CHECKOUT = "actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1"


class RequiredCiWorkflowTest(unittest.TestCase):
    def test_real_core_lifetimes_are_inside_the_required_flutter_aggregate(self):
        workflow = (WORKFLOWS / 'analyze-test.yml').read_text()
        core = workflow.partition('  normal-core-acceptance:\n')[2].split(
            '\n  analyze-test:', 1)[0]
        self.assertTrue(core)
        self.assertIn('feature: [f04, f05, f19, f20, f54]', core)
        self.assertIn('fail-fast: false', core)
        self.assertIn('ref: ${{ github.sha }}', core)
        self.assertIn('test "$(git rev-parse HEAD)" = "$GITHUB_SHA"', core)
        self.assertIn('uv sync --locked --no-editable --python 3.12.14', core)
        self.assertIn('uv run --locked --no-sync python "$runner"', core)
        self.assertIn('*) exit 1 ;;', core)
        self.assertNotIn('continue-on-error', core)
        for feature in ('f04', 'f05', 'f19', 'f20', 'f54'):
            self.assertIn(
                feature + ') runner=tests/support/' + feature +
                '_flutter_acceptance.py ;;', core)
        aggregate = workflow.partition('  analyze-test:\n')[2]
        self.assertIn(
            'needs: [static-analysis, flutter-test, normal-core-acceptance]',
            aggregate)
        self.assertIn('CORE_RESULT: ${{ needs.normal-core-acceptance.result }}',
                      aggregate)

    def test_actual_f54_delivery_blocks_android_after_broad_native_verification(self):
        workflow = (WORKFLOWS / 'android-build.yml').read_text()
        job = workflow.partition('  build-debug-apk:\n')[2].split(
            '\n  build-signed-release-apk:', 1)[0]
        steps = (
            'Verify both native engines in the one debug APK',
            'Native audio, kiosk, window, health privacy and platform contracts',
            'Retain broad JVM proof before the selected F54 clean task',
            'Install the reviewed F54 Core dependency lock',
            'Require normal HTTPS Core and actual WorkManager delivery',
            'Preserve native test evidence',
        )
        positions = [job.index('- name: ' + step) for step in steps]
        self.assertEqual(positions, sorted(positions))
        gate = job.partition('- name: ' + steps[4] + '\n')[2].split(
            '\n      - name:', 1)[0]
        self.assertIn("if: steps.android_scope.outputs.run == 'true'", gate)
        self.assertIn('LARENOR_PRODUCT_NATIVE_ENGINES: required', gate)
        self.assertIn('set -euo pipefail', gate)
        self.assertIn('umask 077', gate)
        self.assertIn('uv run --locked --no-sync python '
                      'tests/support/f54_native_service_acceptance.py', gate)
        self.assertNotIn('continue-on-error', gate)
        self.assertNotIn('|| true', gate)
        self.assertIn('${{ runner.temp }}/larenor-broad-jvm-proof/', job)

    def test_selected_native_clean_does_not_erase_broad_report_proof(self):
        workflow = (WORKFLOWS / 'android-build.yml').read_text()
        step = workflow.partition(
            '- name: Retain broad JVM proof before the selected F54 clean task\n'
        )[2].split('\n      - name:', 1)[0]
        script = textwrap.dedent(step.partition('        run: |\n')[2])
        self.assertTrue(script)
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            runner = root / 'runner'
            runner.mkdir()
            source = root / 'build/app'
            for path in ('reports/tests/testDebugUnitTest/index.html',
                         'test-results/testDebugUnitTest/TEST-Broad.xml'):
                target = source / path
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(b'owned prior broad report')
            subprocess.run(['bash', '-e', '-o', 'pipefail', '-c', script],
                           cwd=root, env={**os.environ, 'RUNNER_TEMP': str(runner)},
                           check=True, capture_output=True)
            shutil.rmtree(source)
            retained = runner / 'larenor-broad-jvm-proof'
            for path in ('reports/index.html', 'results/TEST-Broad.xml'):
                self.assertEqual((retained / path).read_bytes(),
                                 b'owned prior broad report')

    def test_native_aggregates_keep_required_names_and_read_only_pr_access(self):
        for component in ("jellyfin", "qbittorrent", "arr", "seerr", "music-assistant"):
            with self.subTest(component=component):
                value = json.loads((WORKFLOWS / (
                    component + "-managed-characterization.yml")).read_text())
                job = value["jobs"]["native-acceptance"]
                self.assertEqual(job["name"], component + "-native-acceptance")
                self.assertEqual(job["if"], "always()")
                self.assertEqual(job["permissions"], {
                    "contents": "read", "pull-requests": "read"})
                self.assertEqual(job["steps"][0]["uses"], CHECKOUT)
                step = job["steps"][1]
                self.assertEqual(step["run"],
                                 "python3 tool/required_ci_aggregate.py native")
                self.assertEqual(step["env"]["GITHUB_TOKEN"], "${{ github.token }}")
                self.assertEqual(set(step["env"]), {
                    "RUN_NATIVE", "SCOPE_RESULT", "MATRIX_RESULT", "GITHUB_TOKEN"})

    def test_reusable_aggregates_remain_required_and_caller_grants_only_read(self):
        caller = (WORKFLOWS / "android-build.yml").read_text()
        for name, kind in (("server-test", "server"), ("analyze-test", "flutter")):
            with self.subTest(name=name):
                workflow = (WORKFLOWS / (name + ".yml")).read_text()
                required = workflow[workflow.index("  " + name + ":\n"):]
                self.assertIn("    if: always()", required)
                self.assertIn("      pull-requests: read", required)
                self.assertIn("persist-credentials: false", required)
                self.assertIn("GITHUB_TOKEN: ${{ github.token }}", required)
                self.assertIn("python3 tool/required_ci_aggregate.py " + kind,
                              required)
                caller_job = caller.partition("  " + name + ":\n")[2].split(
                    "\n\n  ", 1)[0]
                self.assertIn("      contents: read", caller_job)
                self.assertIn("      pull-requests: read", caller_job)


if __name__ == "__main__":
    unittest.main()
