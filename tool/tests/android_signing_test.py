import base64
import json
from pathlib import Path
import stat
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from android_signing import (ANDROID_MAX_VERSION, ROOT, SECRET_NAMES, VERSION_BASE,
                             SigningError, normalized_fingerprint, prepare_ci,
                             private_write, properties_value, provision,
                             secret_status, upload, validate_apk_output, version_code)
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
        signature = f"Signer #1 certificate SHA-256 digest: {FINGERPRINT}\n"
        badging = "package: name='com.ersingundem.larenor' versionCode='100000001' versionName='1.0.0'\n"
        self.assertEqual(validate_apk_output(signature, badging, FINGERPRINT, version_code("1")), "1.0.0")
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

    def test_signing_workflow_rejects_untrusted_missing_cleanup_or_broad_artifacts(self):
        workflow = (ROOT / ".github/workflows/android-build.yml").read_text()
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
