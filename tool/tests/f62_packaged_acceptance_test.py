import hashlib
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest import mock

from tool import f62_packaged_acceptance as runner


class PackagedRdpReceiptTest(unittest.TestCase):
    def test_owned_host_package_versions_are_bounded_and_explicit(self):
        values = {
            "RDP_ACCEPTANCE_SHADOW_PACKAGE_VERSION": "3.8.0+dfsg-3build3",
            "RDP_ACCEPTANCE_WINPR_PACKAGE_VERSION": "3.8.0+dfsg-3build3",
        }
        with mock.patch.dict(os.environ, values, clear=False):
            versions = runner.fixture_package_versions()
        self.assertEqual(
            versions,
            {
                "freerdp3-shadow-x11": "3.8.0+dfsg-3build3",
                "winpr3-utils": "3.8.0+dfsg-3build3",
            },
        )
        receipt = runner.acceptance_receipt(
            versions,
            revision="a" * 40,
            package_digest="b" * 64,
        )
        self.assertEqual(receipt["ownedHostPackages"], versions)
        self.assertEqual(receipt["sourceRevision"], "a" * 40)
        self.assertEqual(receipt["packageReceiptSha256"], "b" * 64)
        self.assertEqual(
            {key: receipt[key] for key in ("tests", "skipped", "failures", "errors")},
            {"tests": 1, "skipped": 0, "failures": 0, "errors": 0},
        )
        for invalid in ("", "(none)", "version with spaces", "x" * 129):
            values["RDP_ACCEPTANCE_SHADOW_PACKAGE_VERSION"] = invalid
            with mock.patch.dict(os.environ, values, clear=False):
                with self.assertRaises(runner.AcceptanceFailure):
                    runner.fixture_package_versions()
        for revision, digest in (
            ("A" * 40, "b" * 64),
            ("a" * 39, "b" * 64),
            ("a" * 40, "B" * 64),
            ("a" * 40, "b" * 63),
        ):
            with self.assertRaises(runner.AcceptanceFailure):
                runner.acceptance_receipt(
                    versions,
                    revision=revision,
                    package_digest=digest,
                )

    def test_only_the_exact_executed_class_and_method_can_receipt(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            report = directory / "TEST-device.xml"
            valid = (
                '<testsuite tests="1" skipped="0" failures="0" errors="0">'
                f'<testcase classname="{runner.TEST_CLASS}" '
                f'name="{runner.TEST_NAME}"/></testsuite>'
            )
            report.write_text(valid)
            self.assertEqual(runner.verify_reports(directory), report)
            for altered in (
                valid.replace('tests="1"', 'tests="0"'),
                valid.replace('skipped="0"', 'skipped="1"'),
                valid.replace('failures="0"', 'failures="1"'),
                valid.replace('errors="0"', 'errors="1"'),
                valid.replace(runner.TEST_CLASS, "OtherTest"),
                valid.replace(runner.TEST_NAME, "anotherMethod"),
                valid.replace('/></testsuite>', '><skipped/></testcase></testsuite>'),
                valid.replace('/></testsuite>', '><failure/></testcase></testsuite>'),
                "<broken",
            ):
                report.write_text(altered)
                with self.assertRaises(runner.AcceptanceFailure):
                    runner.verify_reports(directory)
            report.write_text(valid)
            (directory / "TEST-stale.xml").write_text(valid)
            with self.assertRaises(runner.AcceptanceFailure):
                runner.verify_reports(directory)
            report.unlink()
            (directory / "TEST-stale.xml").unlink()
            with self.assertRaises(runner.AcceptanceFailure):
                runner.verify_reports(directory)

    def test_package_receipt_digest_rejects_nonregular_inputs(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            receipt = root / "receipt.json"
            receipt.write_bytes(b'{"schemaVersion":1}\n')
            expected = hashlib.sha256(receipt.read_bytes()).hexdigest()
            self.assertEqual(runner.package_receipt_digest(receipt), expected)

            alias = root / "alias.json"
            alias.symlink_to(receipt)
            with self.assertRaises(runner.AcceptanceFailure):
                runner.package_receipt_digest(alias)
            receipt.unlink()
            receipt.mkdir()
            with self.assertRaises(runner.AcceptanceFailure):
                runner.package_receipt_digest(receipt)

    def test_public_receipt_is_canonical_private_and_exclusive(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary).resolve() / "receipt.json"
            receipt = runner.acceptance_receipt(
                {
                    "freerdp3-shadow-x11": "3.8.0+dfsg-3build3",
                    "winpr3-utils": "3.8.0+dfsg-3build3",
                },
                revision="a" * 40,
                package_digest="b" * 64,
            )
            runner.write_public_receipt(path, receipt)
            self.assertEqual(
                path.read_text(),
                json.dumps(
                    receipt,
                    ensure_ascii=True,
                    separators=(",", ":"),
                    sort_keys=True,
                ) + "\n",
            )
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            with self.assertRaises(runner.AcceptanceFailure):
                runner.write_public_receipt(path, receipt)

    def test_publication_removes_raw_junit_and_binds_source_and_package(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            report = root / "TEST-device.xml"
            report.write_text("<testsuite/>")
            versions = {
                "freerdp3-shadow-x11": "3.8.0+dfsg-3build3",
                "winpr3-utils": "3.8.0+dfsg-3build3",
            }
            with (
                mock.patch.object(runner, "source_revision", return_value="a" * 40),
                mock.patch.object(
                    runner, "package_receipt_digest", return_value="b" * 64
                ),
            ):
                path = runner.publish_public_receipt(report, root, versions)
            self.assertFalse(report.exists())
            self.assertEqual(path.parent.stat().st_mode & 0o777, 0o700)
            self.assertEqual(
                json.loads(path.read_text()),
                runner.acceptance_receipt(
                    versions,
                    revision="a" * 40,
                    package_digest="b" * 64,
                ),
            )


if __name__ == "__main__":
    unittest.main()
