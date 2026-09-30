from pathlib import Path
import tempfile
import unittest

from tool import f62_packaged_acceptance as runner


class PackagedRdpReceiptTest(unittest.TestCase):
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
            runner.verify_reports(directory)
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


if __name__ == "__main__":
    unittest.main()
