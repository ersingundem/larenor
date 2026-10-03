from __future__ import annotations

import hashlib
import importlib.util
import json
from pathlib import Path
import stat
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "tool/f62_gateway_android_hosted.py"
SPEC = importlib.util.spec_from_file_location("f62_gateway_android_hosted", SCRIPT)
assert SPEC and SPEC.loader
hosted = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(hosted)


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def private_json(path: Path, value: dict) -> None:
    path.write_text(json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n")
    path.chmod(0o600)


class HostedGatewayAndroidTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.base = Path(self.temporary.name)
        self.source = self.base / "source"
        self.output = self.base / "output"
        self.product = self.base / "product"
        for directory in (self.source, self.output, self.product):
            directory.mkdir(mode=0o700)
        paths = {
            "tool/f62_gateway_saf_acceptance_contract.py": b"placeholder\n",
            "tool/f62_gateway_saf_android_client.py": b"client\n",
            "tool/f62_rdpgw_owned_fixture.py": b"fixture\n",
            "tool/f62_gateway_android_hosted.py": SCRIPT.read_bytes(),
            hosted.SCENARIOS["direct"]["test"]: b"test-source\n",
            "android/app/src/androidTest/AndroidManifest.xml": b"<manifest/>\n",
            "android/app/src/freerdpAndroidTest/kotlin/com/ersingundem/larenor/rdp/RdpOwnedSafDocumentsProvider.kt": b"provider\n",
        }
        for relative, content in paths.items():
            path = self.source / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(content)
            path.chmod(0o644)
        claimed = {
            relative: digest(self.source / relative)
            for relative in (
                hosted.SCENARIOS["direct"]["test"],
                "android/app/src/androidTest/AndroidManifest.xml",
                "android/app/src/freerdpAndroidTest/kotlin/com/ersingundem/larenor/rdp/RdpOwnedSafDocumentsProvider.kt",
            )
        }
        contract = self.source / hosted.SCENARIOS["direct"]["contract"]
        contract.write_text(
            "import json\n"
            f"print(json.dumps({json.dumps({'testClass': hosted.SCENARIOS['direct']['testClass'], 'testName': hosted.SCENARIOS['direct']['testName'], 'sourceSha256': claimed})}))\n"
        )
        self.adb = self.base / "adb"
        self.adb.write_text("#!/bin/sh\nexit 0\n")
        self.adb.chmod(0o700)
        self.git = self.base / "git"
        self.git.write_text(
            f"#!{sys.executable}\n"
            "import sys\n"
            "value = '1' * 40 if sys.argv[-1] == 'HEAD' else '2' * 40\n"
            "print(value)\n"
        )
        self.git.chmod(0o700)
        self.compile_log = self.base / "compile.log"
        self.compile_log.write_bytes(b"bounded-private-compile\n")
        self.compile_log.chmod(0o600)
        self.inputs = {}
        for name in ("app.apk", "test.apk", "product-receipt.json", "product-verifier.py", "fixture.py"):
            path = self.base / name
            path.write_bytes(name.encode("ascii"))
            path.chmod(0o644)
            self.inputs[name] = path

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def prepare_args(self) -> list[str]:
        return [
            "prepare", "--scenario", "direct", "--source", str(self.source),
            "--output", str(self.output), "--python", sys.executable,
            "--adb", str(self.adb), "--git", str(self.git),
            "--compile-log", str(self.compile_log),
            "--app-apk", str(self.inputs["app.apk"]),
            "--test-apk", str(self.inputs["test.apk"]),
            "--product-native-dir", str(self.product),
            "--product-receipt", str(self.inputs["product-receipt.json"]),
            "--product-verifier", str(self.inputs["product-verifier.py"]),
            "--fixture-source", str(self.inputs["fixture.py"]),
            "--private-log", str(self.output / "instrumentation.log"),
        ]

    def test_prepare_binds_contract_sources_and_private_command(self) -> None:
        self.assertEqual(hosted.main(self.prepare_args()), 0)
        manifest = json.loads((self.output / "source-manifest.json").read_text())
        self.assertEqual(
            set(manifest),
            {"schemaVersion", "targetPatchSha256", "targetSourceManifestSha256", "compileLogSha256", "files"},
        )
        self.assertEqual(manifest["compileLogSha256"], digest(self.compile_log))
        self.assertEqual(manifest["files"][hosted.SCENARIOS["direct"]["test"]], digest(self.source / hosted.SCENARIOS["direct"]["test"]))
        command = json.loads((self.output / "client-command.json").read_text())["argv"]
        self.assertEqual(command[command.index("--scenario") + 1], "direct")
        self.assertEqual(
            command[command.index("--product-native-dir") + 1],
            str(self.product.resolve()),
        )
        for name in ("source-manifest.json", "android-build-receipt.json", "client-command.json", "launcher-receipt.json"):
            self.assertEqual(stat.S_IMODE((self.output / name).stat().st_mode), 0o600)
        launcher = json.loads((self.output / "launcher-receipt.json").read_text())
        self.assertEqual(launcher["checkoutRevision"], "1" * 40)
        self.assertEqual(launcher["checkoutTree"], "2" * 40)

    def test_claimed_source_drift_is_rejected(self) -> None:
        test = self.source / hosted.SCENARIOS["direct"]["test"]
        test.write_text("changed\n")
        self.assertEqual(hosted.main(self.prepare_args()), 2)
        self.assertFalse((self.output / "source-manifest.json").exists())

    def valid_receipt(self) -> dict:
        value = {
            "schemaVersion": 2,
            "sourceRevision": hosted.RDGW_REVISION,
            "archiveSha256": hosted.RDGW_ARCHIVE_SHA256,
            "goVersion": "go1.25.0",
            "goSumSha256": "a" * 64,
            "gatewayBinarySha256": "b" * 64,
            "authBinarySha256": "c" * 64,
            "testClass": hosted.SCENARIOS["direct"]["testClass"],
            "testName": hosted.SCENARIOS["direct"]["testName"],
            "tests": 1, "failures": 0, "errors": 0, "skipped": 0,
            "featureAccepted": False,
            "scope": "ownedRdGatewaySafPrepared",
        }
        value.update({key: True for key in hosted.PUBLIC_FACTS})
        return value

    def test_receipt_accepts_exact_revision_and_rejects_stale_or_acceptance_claim(self) -> None:
        receipt = self.base / "receipt.json"
        private_json(receipt, self.valid_receipt())
        self.assertEqual(hosted.main(["validate-receipt", "--scenario", "direct", "--receipt", str(receipt)]), 0)
        receipt.unlink()
        stale = self.valid_receipt()
        stale["sourceRevision"] = "0" * 40
        private_json(receipt, stale)
        self.assertEqual(hosted.main(["validate-receipt", "--scenario", "direct", "--receipt", str(receipt)]), 2)
        receipt.unlink()
        accepted = self.valid_receipt()
        accepted["featureAccepted"] = True
        private_json(receipt, accepted)
        self.assertEqual(hosted.main(["validate-receipt", "--scenario", "direct", "--receipt", str(receipt)]), 2)

    def test_receipt_rejects_boolean_schema_and_named_counts(self) -> None:
        for key in ("schemaVersion", "tests", "failures", "errors", "skipped"):
            with self.subTest(key=key):
                receipt = self.base / (key + ".json")
                value = self.valid_receipt()
                value[key] = bool(value[key])
                private_json(receipt, value)
                self.assertEqual(hosted.main([
                    "validate-receipt", "--scenario", "direct", "--receipt", str(receipt),
                ]), 2)

    def test_joined_receipt_binds_effect_build_source_target_and_checkout(self) -> None:
        self.assertEqual(hosted.main(self.prepare_args()), 0)
        effect = self.base / "effect.json"
        private_json(effect, self.valid_receipt())
        joined = self.base / "joined.json"
        command = [
            "join-receipt", "--scenario", "direct",
            "--effect-receipt", str(effect),
            "--launcher-receipt", str(self.output / "launcher-receipt.json"),
            "--android-build-receipt", str(self.output / "android-build-receipt.json"),
            "--source-manifest", str(self.output / "source-manifest.json"),
            "--output", str(joined),
        ]
        self.assertEqual(hosted.main(command), 0)
        value = json.loads(joined.read_text())
        self.assertEqual(set(value), hosted.JOINED_KEYS)
        self.assertEqual(value["schemaVersion"], 3)
        self.assertEqual(value["checkoutRevision"], "1" * 40)
        self.assertEqual(value["checkoutTree"], "2" * 40)
        self.assertEqual(value["effectReceiptSha256"], digest(effect))
        self.assertEqual(value["sourceManifestSha256"], digest(self.output / "source-manifest.json"))
        self.assertEqual(value["targetPatchSha256"], hosted.TARGET_PATCH_SHA256)
        self.assertFalse(value["featureAccepted"])
        self.assertEqual(hosted.main([
            "validate-joined-receipt", "--scenario", "direct", "--receipt", str(joined),
        ]), 0)

    def test_join_rejects_cross_scenario_drift_and_extra_binding_keys(self) -> None:
        self.assertEqual(hosted.main(self.prepare_args()), 0)
        effect = self.base / "effect.json"
        private_json(effect, self.valid_receipt())
        joined = self.base / "joined.json"
        command = [
            "join-receipt", "--scenario", "public",
            "--effect-receipt", str(effect),
            "--launcher-receipt", str(self.output / "launcher-receipt.json"),
            "--android-build-receipt", str(self.output / "android-build-receipt.json"),
            "--source-manifest", str(self.output / "source-manifest.json"),
            "--output", str(joined),
        ]
        self.assertEqual(hosted.main(command), 2)
        self.assertFalse(joined.exists())

        valid = self.base / "valid-joined.json"
        direct = command.copy()
        direct[direct.index("public")] = "direct"
        direct[direct.index(str(joined))] = str(valid)
        self.assertEqual(hosted.main(direct), 0)
        value = json.loads(valid.read_text())
        value["privatePath"] = "/private/value"
        invalid = self.base / "invalid-joined.json"
        private_json(invalid, value)
        self.assertEqual(hosted.main([
            "validate-joined-receipt", "--scenario", "direct", "--receipt", str(invalid),
        ]), 2)

    def test_join_rejects_private_build_binding_drift(self) -> None:
        self.assertEqual(hosted.main(self.prepare_args()), 0)
        effect = self.base / "effect.json"
        private_json(effect, self.valid_receipt())
        build = self.output / "android-build-receipt.json"
        value = json.loads(build.read_text())
        value["appApkSha256"] = "f" * 64
        private_json(build, value)
        joined = self.base / "joined.json"
        self.assertEqual(hosted.main([
            "join-receipt", "--scenario", "direct",
            "--effect-receipt", str(effect),
            "--launcher-receipt", str(self.output / "launcher-receipt.json"),
            "--android-build-receipt", str(build),
            "--source-manifest", str(self.output / "source-manifest.json"),
            "--output", str(joined),
        ]), 2)
        self.assertFalse(joined.exists())


if __name__ == "__main__":
    unittest.main(verbosity=2)
