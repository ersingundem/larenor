import os
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SERVER = (ROOT / ".github/workflows/server-test.yml").read_text()
WORKFLOW = (ROOT / ".github/workflows/f62-gateway-android-direct.yml").read_text()
SOURCE_ROOT = Path(os.environ.get("LARENOR_WORKFLOW_SOURCE_ROOT", ROOT))
ANDROID_BUILD = (SOURCE_ROOT / "android/build.gradle.kts").read_text()


def _binding_script() -> str:
    start = WORKFLOW.index("      - name: Bind one closed registered scenario")
    run = WORKFLOW.index("        run: |\n", start) + len("        run: |\n")
    end = WORKFLOW.index("\n\n      - name:", run)
    return textwrap.dedent(WORKFLOW[run:end])


def _bind(scenario: str) -> tuple[subprocess.CompletedProcess[str], dict[str, str]]:
    with tempfile.TemporaryDirectory() as directory:
        output = Path(directory) / "github-env"
        environment = dict(os.environ)
        environment["REQUESTED_SCENARIO"] = scenario
        environment["GITHUB_ENV"] = str(output)
        result = subprocess.run(
            ["bash", "-c", _binding_script()],
            check=False,
            env=environment,
            stdin=subprocess.DEVNULL,
            capture_output=True,
            text=True,
            timeout=5,
        )
        values = {}
        if output.exists():
            for line in output.read_text().splitlines():
                key, value = line.split("=", 1)
                values[key] = value
        return result, values


class GatewayAndroidRegisteredWorkflowTest(unittest.TestCase):
    def test_only_server_dispatch_registers_literal_direct_and_public_calls(self) -> None:
        for scope, scenario in (
            ("f62-gateway-android-direct", "direct"),
            ("f62-gateway-android-public", "public"),
        ):
            self.assertEqual(SERVER.count(f"          - {scope}\n"), 1)
            self.assertIn(
                "if: github.event_name == 'workflow_dispatch' "
                f"&& inputs.scope == '{scope}'",
                SERVER,
            )
            job = SERVER[SERVER.index(f"  {scope}:") :]
            self.assertIn("uses: ./.github/workflows/f62-gateway-android-direct.yml", job)
            self.assertIn(f"      scenario: {scenario}", job)
        self.assertIn("  workflow_call:", WORKFLOW)
        self.assertNotIn("  workflow_dispatch:", WORKFLOW)
        self.assertIn("        required: true", WORKFLOW)
        self.assertIn("        type: string", WORKFLOW)

    def test_scenario_binding_is_closed_and_rejects_untrusted_values(self) -> None:
        expected = {
            "direct": {
                "LARENOR_F62_SCENARIO": "direct",
                "LARENOR_F62_ROOT_SUFFIX": "direct",
                "LARENOR_F62_TEST_CLASS": (
                    "com.ersingundem.larenor.rdp.RdpPackagedGatewaySafAcceptanceTest"
                ),
                "LARENOR_F62_TEST_NAME": (
                    "gatewaySafProvesTwoHopPinsNlaAndRdpdrRoundTripAfterExplicitDrain"
                ),
                "LARENOR_F62_RAW_RECEIPT_NAME": (
                    "f62-gateway-android-direct-raw-effect.json"
                ),
                "LARENOR_F62_JOINED_RECEIPT_NAME": (
                    "f62-gateway-android-direct-receipt.json"
                ),
                "LARENOR_F62_RESULT_NAME": (
                    "f62-gateway-android-direct-receipt.json"
                ),
            },
            "public": {
                "LARENOR_F62_SCENARIO": "public",
                "LARENOR_F62_ROOT_SUFFIX": "public",
                "LARENOR_F62_TEST_CLASS": (
                    "com.ersingundem.larenor.rdp."
                    "RdpPackagedGatewaySafPublicBridgeAcceptanceTest"
                ),
                "LARENOR_F62_TEST_NAME": (
                    "gatewaySafPublicMethodChannelPathProvesTwoPinsNlaRdpdrDrainAndSafReadback"
                ),
                "LARENOR_F62_RAW_RECEIPT_NAME": (
                    "f62-gateway-android-public-raw-effect.json"
                ),
                "LARENOR_F62_JOINED_RECEIPT_NAME": (
                    "f62-gateway-android-public-receipt.json"
                ),
                "LARENOR_F62_RESULT_NAME": (
                    "f62-gateway-android-public-receipt.json"
                ),
            },
        }
        for scenario, values in expected.items():
            result, actual = _bind(scenario)
            self.assertEqual(result.returncode, 0)
            self.assertEqual(actual, values)
        for rejected in ("", "DIRECT", "direct; touch injected", "public/../direct"):
            result, values = _bind(rejected)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(values, {})
        self.assertEqual(WORKFLOW.count("${{ inputs.scenario }}"), 1)
        self.assertIn("REQUESTED_SCENARIO: ${{ inputs.scenario }}", WORKFLOW)

    def test_exact_source_identity_and_pinned_actions_are_required(self) -> None:
        for text in (
            'test "$GITHUB_EVENT_NAME" = workflow_dispatch',
            'test "$GITHUB_REPOSITORY" = ersingundem/larenor',
            'test "$RUNNER_ENVIRONMENT" = github-hosted',
            'test "$(git rev-parse HEAD)" = "$GITHUB_SHA"',
            "actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1",
            "actions/setup-java@de7274f081f381c8f8158605e0321c36c376e2e6",
            "android-actions/setup-android@be39fa834029ff78f1a44aa3bb0819b8fc2bd8fd",
            "subosito/flutter-action@1a449444c387b1966244ae4d4f8c696479add0b2",
            "ReactiveCircus/android-emulator-runner@a421e43855164a8197daf9d8d40fe71c6996bb0d",
        ):
            self.assertIn(text, WORKFLOW)

    def test_both_scenarios_build_the_same_fresh_dual_native_product(self) -> None:
        self.assertIn("timeout-minutes: 90", WORKFLOW)
        self.assertIn("for abi in arm64-v8a x86_64", WORKFLOW)
        self.assertIn("tool/moonlight_android_package.py build", WORKFLOW)
        self.assertIn("tool/freerdp_android_package.py verify-patch", WORKFLOW)
        self.assertEqual(WORKFLOW.count("tool/product_android_native.py install"), 1)
        self.assertIn(
            'for destination in "$root/product-native/app" "$GITHUB_WORKSPACE/android/app"',
            WORKFLOW,
        )
        self.assertIn(
            "flutter build apk --debug --target-platform android-arm64,android-x64",
            WORKFLOW,
        )
        self.assertIn(":app:assembleDebugAndroidTest", WORKFLOW)
        self.assertIn('.dir("../../build")', ANDROID_BUILD)
        self.assertIn(
            "project.layout.buildDirectory.value(newSubprojectBuildDir)",
            ANDROID_BUILD,
        )
        self.assertIn(
            "test=build/app/outputs/apk/androidTest/debug/app-debug-androidTest.apk",
            WORKFLOW,
        )
        self.assertNotIn(
            "test=android/app/build/outputs/apk/androidTest/debug/"
            "app-debug-androidTest.apk",
            WORKFLOW,
        )
        self.assertIn("tool/product_android_native.py verify-apk", WORKFLOW)
        self.assertIn("LARENOR_PRODUCT_NATIVE_ENGINES: required", WORKFLOW)
        self.assertNotIn("actions/cache", WORKFLOW)

    def test_registered_scenario_runs_the_source_bound_real_adapter(self) -> None:
        for text in (
            "tool/f62_rdpgw_owned_fixture.py build",
            "tool/f62_gateway_linux_probe.py build-freerdp",
            "tool/f62_rdpgw_owned_fixture.py run-android",
            '--git "$(command -v git)"',
            '--scenario "$LARENOR_F62_SCENARIO"',
            '--expected-test-class "$LARENOR_F62_TEST_CLASS"',
            '--expected-test-name "$LARENOR_F62_TEST_NAME"',
            '--public-receipt "$root/$LARENOR_F62_RAW_RECEIPT_NAME"',
            "tool/f62_gateway_android_hosted.py join-receipt",
            '--effect-receipt "$root/$LARENOR_F62_RAW_RECEIPT_NAME"',
            '--launcher-receipt "$root/hosted/launcher-receipt.json"',
            '--android-build-receipt "$root/hosted/android-build-receipt.json"',
            '--source-manifest "$root/hosted/source-manifest.json"',
            '--output "$root/$LARENOR_F62_JOINED_RECEIPT_NAME"',
            "tool/f62_gateway_android_hosted.py validate-joined-receipt",
            '--receipt "$root/$LARENOR_F62_JOINED_RECEIPT_NAME"',
            "--client-timeout 900",
        ):
            self.assertIn(text, WORKFLOW)
        self.assertNotIn("featureAccepted: true", WORKFLOW)
        self.assertNotIn("acceptance override", WORKFLOW.lower())
        self.assertNotIn("bypass", WORKFLOW.lower())
        self.assertNotIn("fake", WORKFLOW.lower())
        self.assertNotIn(
            "test-results/$LARENOR_F62_RAW_RECEIPT_NAME",
            WORKFLOW,
        )

    def test_success_artifacts_are_fixed_and_cleanup_precedes_upload(self) -> None:
        cleanup = WORKFLOW.index(
            "Remove private native, network, descriptor, and emulator inputs"
        )
        direct = WORKFLOW.index("Preserve only the closed DIRECT joined receipt")
        public = WORKFLOW.index("Preserve only the closed PUBLIC joined receipt")
        self.assertLess(cleanup, direct)
        self.assertLess(cleanup, public)
        for scenario in ("direct", "public"):
            self.assertIn(f"if: success() && inputs.scenario == '{scenario}'", WORKFLOW)
            self.assertIn(
                f"name: larenor-f62-gateway-android-{scenario}", WORKFLOW
            )
            self.assertIn(
                f"path: test-results/f62-gateway-android-{scenario}-receipt.json",
                WORKFLOW,
            )
        upload = WORKFLOW[min(direct, public) :]
        for private in (
            "instrumentation.log",
            "android-build.log",
            "private-session.json",
            "gateway.yaml",
        ):
            self.assertNotIn(private, upload)
        self.assertIn("if: always()", WORKFLOW)
        self.assertIn("tool/f62_rdpgw_owned_fixture.py cleanup", WORKFLOW)
        self.assertIn("rm -rf --one-file-system", WORKFLOW)
        self.assertIn("f62-gateway-android-build-failure.json", WORKFLOW)
        self.assertIn("f62-gateway-build-failure.json", WORKFLOW)


if __name__ == "__main__":
    unittest.main(verbosity=2)
