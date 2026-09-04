import base64
import json
import hashlib
from pathlib import Path
import stat
import sys
import tempfile
import unittest
import subprocess
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from android_signing import (ANDROID_MAX_VERSION, ROOT, SECRET_NAMES, VERSION_BASE,
                             SigningError, normalized_fingerprint, prepare_ci,
                             private_write, properties_value, provision,
                             secret_status, upload, validate_apk_output, version_code, file_sha256,
                             apk_certificate_fingerprint, build_tool, verify_apk, run)
from check_security_policy import validate_signed_android_workflow

FINGERPRINT = "ab" * 32
SECRETS = dict(zip(SECRET_NAMES, [base64.b64encode(b"private fixture key").decode(),
                                "fixture=password\\with:escapes", "release", "key password", FINGERPRINT]))


class AndroidSigningTest(unittest.TestCase):
    def test_version_codes_increase_and_are_android_bounded(self):
        self.assertEqual(version_code("1"), VERSION_BASE + 1)
        self.assertGreater(version_code("124"), version_code("123"))
        self.assertEqual(version_code(str(ANDROID_MAX_VERSION - VERSION_BASE)), ANDROID_MAX_VERSION)
        for value in ("", "0", "-1", "1.2", str(ANDROID_MAX_VERSION)):
            with self.assertRaises(SigningError):
                version_code(value)

    def test_missing_secrets_skip_but_partial_configuration_fails_closed(self):
        self.assertFalse(secret_status({}))
        self.assertTrue(secret_status(SECRETS))
        with self.assertRaises(SigningError):
            secret_status({SECRET_NAMES[0]: "private fixture"})

    def test_fingerprint_accepts_colons_but_not_truncated_digests(self):
        self.assertEqual(normalized_fingerprint(":".join(["AB"] * 32)), FINGERPRINT)
        with self.assertRaises(SigningError):
            normalized_fingerprint("AB:CD")

    def test_private_creation_never_overwrites_files_or_symlinks(self):
        with tempfile.TemporaryDirectory() as raw:
            directory = Path(raw)
            original = directory / "original"
            private_write(original, b"original")
            self.assertEqual(stat.S_IMODE(original.stat().st_mode), 0o600)
            with self.assertRaises(FileExistsError):
                private_write(original, b"replacement")
            link = directory / "link"
            link.symlink_to(original)
            with self.assertRaises(FileExistsError):
                private_write(link, b"replacement")
            self.assertEqual(original.read_bytes(), b"original")

    def test_ci_material_is_private_and_uses_java_properties_escaping(self):
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw) / "repo"
            (root / "android").mkdir(parents=True)
            temporary = Path(raw) / "runner"
            temporary.mkdir()
            with patch("android_signing.certificate_fingerprint", return_value=FINGERPRINT):
                self.assertTrue(prepare_ci(root, temporary, SECRETS))
            properties = root / "android/key.properties"
            self.assertEqual(stat.S_IMODE(properties.stat().st_mode), 0o600)
            self.assertEqual(stat.S_IMODE((temporary / "larenor-signing").stat().st_mode), 0o700)
            self.assertIn("storePassword=fixture\\=password\\\\with\\:escapes\n", properties.read_text())
            self.assertIn("keyPassword=key\\ password\n", properties.read_text())
            self.assertEqual(properties_value("ş\n🔒"), "\\u015f\\u000a\\ud83d\\udd12")
            with self.assertRaises(SigningError):
                prepare_ci(root, temporary, SECRETS)

    def test_wrong_certificate_never_creates_gradle_signing_configuration(self):
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw) / "repo"
            (root / "android").mkdir(parents=True)
            with patch("android_signing.certificate_fingerprint", return_value="cd" * 32):
                with self.assertRaises(SigningError):
                    prepare_ci(root, Path(raw), SECRETS)
            self.assertFalse((root / "android/key.properties").exists())

    def test_invalid_base64_fails_without_exposing_key_value(self):
        with tempfile.TemporaryDirectory() as raw:
            with self.assertRaises(SigningError) as result:
                prepare_ci(Path(raw), Path(raw), dict(SECRETS, ANDROID_RELEASE_KEYSTORE_BASE64="not base64 private value"))
            self.assertNotIn("private value", str(result.exception))
            self.assertFalse((Path(raw) / "larenor-signing").exists())

    def test_provision_refuses_existing_directory_and_repository_location(self):
        with tempfile.TemporaryDirectory() as raw, patch("android_signing.run") as command:
            for directory in (Path(raw), ROOT / "unsafe-signing"):
                with self.assertRaises(SigningError):
                    provision(directory)
            command.assert_not_called()

    def test_upload_refuses_to_replace_existing_github_identity(self):
        with tempfile.TemporaryDirectory() as raw:
            directory = Path(raw)
            directory.chmod(0o700)
            private_write(directory / "release.p12", b"key fixture")
            private_write(directory / "password.txt", b"password fixture")
            private_write(directory / "identity.json", json.dumps({"alias": "release", "certificateSha256": FINGERPRINT}).encode())
            with patch("android_signing.certificate_fingerprint", return_value=FINGERPRINT), patch("android_signing.run", return_value=json.dumps([{"name": SECRET_NAMES[0]}]).encode()) as command:
                with self.assertRaises(SigningError):
                    upload(directory, "example/repository")
                self.assertEqual(command.call_count, 1)
                self.assertEqual(command.call_args.args[0][1:3], ["secret", "list"])

    def test_apk_verification_rejects_debug_tampered_version_and_signer(self):
        signature = f"Number of signers: 1\nSigner #1 certificate SHA-256 digest: {FINGERPRINT}\n"
        badging = "package: name='com.ersingundem.larenor' versionCode='100000001' versionName='1.0.0'\n"
        self.assertEqual(validate_apk_output(signature, badging, FINGERPRINT, version_code("1")), "1.0.0")
        self.assertEqual(validate_apk_output(signature.replace("\n", "\r\n"), badging, FINGERPRINT, version_code("1")), "1.0.0")
        cases = [
            (signature, badging + "application-debuggable\n"),
            (signature, badging.replace("100000001", "1")),
            (signature, badging.replace("com.ersingundem.larenor", "com.example.other")),
            (signature.replace(FINGERPRINT, "cd" * 32), badging),
            (signature + signature.replace("#1", "#2"), badging),
            (signature + "Signer #1 certificate DN: CN=Android Debug, O=Android\n", badging),
        ]
        for signer, manifest in cases:
            with self.assertRaises(SigningError):
                validate_apk_output(signer, manifest, FINGERPRINT, version_code("1"))

    def test_build_tools_37_scheme_specific_certificate_labels(self):
        # Labels reproduced with Google's stable37 apksigner.jar, using the
        # existing release APK and AOSP's public golden/v31 APK fixtures.
        labels = ["Signer #1", "V1 Signer:", "V2 Signer:", "V2 Signer #1:",
                  "V3.0 Signer:", "V3.1 Signer: (minSdkVersion=33, maxSdkVersion=2147483647)",
                  "V3.0 Signer: (minSdkVersion=24, maxSdkVersion=32)",
                  "V3.1 Signer: (minSdkVersion=32 (dev release=true), maxSdkVersion=2147483647)",
                  "Signer (minSdkVersion=24, maxSdkVersion=32)"]
        for label in labels:
            with self.subTest(label=label):
                signature = f"Verifies\r\nNumber of signers: 1\r\n{label} certificate SHA-256 digest: {FINGERPRINT}\r\n"
                self.assertEqual(apk_certificate_fingerprint(signature), FINGERPRINT)
                with self.assertRaises(SigningError):
                    apk_certificate_fingerprint(signature + f"{label} certificate DN: O=Android, CN=Android Debug\n")

    def test_repeated_scheme_records_require_one_identical_pinned_certificate(self):
        records = [f"{label} certificate SHA-256 digest: {FINGERPRINT}\n"
                   for label in ("V1 Signer:", "V2 Signer:",
                                 "V3.1 Signer: (minSdkVersion=33, maxSdkVersion=2147483647)",
                                 "V3.0 Signer: (minSdkVersion=24, maxSdkVersion=32)")]
        signature = "Number of signers: 1\n" + "".join(records)
        badging = "package: name='com.ersingundem.larenor' versionCode='100000001' versionName='1.0.0'\n"
        self.assertEqual(validate_apk_output(signature, badging, FINGERPRINT, version_code("1")), "1.0.0")
        for mixed in (signature.replace(FINGERPRINT, "cd" * 32, 1),
                      signature + f"V2 Signer #2: certificate SHA-256 digest: {FINGERPRINT}\n"):
            with self.assertRaises(SigningError):
                validate_apk_output(mixed, badging, FINGERPRINT, version_code("1"))

    def test_signer_count_unknown_records_and_noncertificate_digests_fail_closed(self):
        certificate = f"V2 Signer: certificate SHA-256 digest: {FINGERPRINT}\n"
        for signature in (certificate, "Number of signers: 0\n" + certificate,
                          "Number of signers: 2\n" + certificate,
                          "Number of signers: 1\nNumber of signers: 1\n" + certificate,
                          "Number of signers: invalid\n" + certificate,
                          "Number of signers: 1\n" + certificate.replace("V2 Signer:", "Unrecognized signer:"),
                          "Number of signers: 1\n" + certificate.replace("certificate", "public key"),
                          "Number of signers: 1\n" + certificate.replace("V2 Signer:", "Source Stamp Signer:"),
                          "Number of signers: 1\n" + certificate + certificate.replace("V2 Signer:", "Unknown:")):
            with self.subTest(signature=signature), self.assertRaises(SigningError):
                apk_certificate_fingerprint(signature)
        # Distribution stamps never satisfy or replace the APK certificate pin.
        signature = "Number of signers: 1\n" + certificate + f"Source Stamp Signer: certificate SHA-256 digest: {'cd' * 32}\n"
        self.assertEqual(apk_certificate_fingerprint(signature), FINGERPRINT)

    def test_verification_tool_selection_is_stable_and_ci_pin_is_required(self):
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            for version in ("36.1.0", "37.0.0", "37.0.0-rc2", "38.0.0-rc1"):
                directory = root / "build-tools" / version
                directory.mkdir(parents=True)
                (directory / "apksigner").touch()
            with patch.dict("os.environ", {"ANDROID_HOME": raw}, clear=True):
                self.assertEqual(Path(build_tool("apksigner")).parent.name, "37.0.0")
            for pin in ("37.0.0-rc2", "../37.0.0", "99.0.0"):
                with patch.dict("os.environ", {"ANDROID_HOME": raw, "ANDROID_BUILD_TOOLS_VERSION": pin}, clear=True):
                    with self.assertRaises(SigningError):
                        build_tool("apksigner")
            with patch.dict("os.environ", {"ANDROID_HOME": raw, "ANDROID_BUILD_TOOLS_VERSION": "36.1.0"}, clear=True):
                self.assertEqual(Path(build_tool("apksigner")).parent.name, "36.1.0")

    def test_nonzero_apksigner_exit_never_writes_metadata_or_exposes_tool_output(self):
        result = subprocess.CompletedProcess(["apksigner"], 1, b"private fixture output", b"private fixture failure")
        with patch("android_signing.subprocess.run", return_value=result):
            with self.assertRaises(SigningError) as failure:
                run(["apksigner", "verify", "fixture.apk"])
            self.assertNotIn("private fixture", str(failure.exception))
        with tempfile.TemporaryDirectory() as raw:
            metadata = Path(raw) / "release-metadata.json"
            with patch("android_signing.build_tool", return_value="apksigner"), \
                    patch("android_signing.run", side_effect=SigningError("Verifier failed")) as command:
                with self.assertRaises(SigningError):
                    verify_apk(Path(raw) / "fixture.apk", FINGERPRINT, version_code("1"), metadata)
                self.assertIn("verify", command.call_args.args[0])
                self.assertEqual(command.call_count, 1)
                self.assertFalse(metadata.exists())

    def test_streaming_apk_digest_crosses_chunk_boundary(self):
        with tempfile.TemporaryDirectory() as raw:
            apk = Path(raw) / "fixture.apk"
            payload = b"fixture" * 200_000
            apk.write_bytes(payload)
            self.assertEqual(file_sha256(apk), hashlib.sha256(payload).hexdigest())

    def test_signing_workflow_rejects_untrusted_missing_cleanup_or_broad_artifacts(self):
        workflow = (ROOT / ".github/workflows/android-build.yml").read_text()
        self.assertIn('ANDROID_BUILD_TOOLS_VERSION: "37.0.0"', workflow)
        self.assertIn('sdkmanager "build-tools;$ANDROID_BUILD_TOOLS_VERSION"', workflow)
        self.assertEqual(validate_signed_android_workflow(workflow), [])
        for change in (
            workflow.replace("github.ref == 'refs/heads/main'", "true"),
            workflow.replace("        if: always()", "        if: success()"),
            workflow.replace("            build/app/outputs/flutter-apk/app-release.apk", "            build/**"),
            workflow.replace("python3 tool/android_signing.py verify-apk", "echo skipped"),
            workflow.replace('if [ "$GITHUB_RUN_ATTEMPT" != "1" ]', 'if false'),
        ):
            self.assertTrue(validate_signed_android_workflow(change))


if __name__ == "__main__":
    unittest.main()
