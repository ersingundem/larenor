import hashlib
import json
import os
from pathlib import Path
import re
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock

from tool import f62_packaged_acceptance as runner

CHANNEL_EVIDENCE_BASE = {
    "enabledClientToRemoteClipboard": True,
    "enabledDisplayControl": True,
    "disabledClipboardTransfers": 0,
    "authenticatedLifetimes": 2,
}
CHANNEL_EVIDENCE = {
    **CHANNEL_EVIDENCE_BASE,
    "shadowBinarySha256": "c" * 64,
}


class PackagedRdpReceiptTest(unittest.TestCase):
    @staticmethod
    def _failure_xml(*, exception_type="java.lang.AssertionError", body=""):
        failure_type = (
            "" if exception_type is None else f' type="{exception_type}"'
        )
        return (
            '<testsuite tests="1" skipped="0" failures="1" errors="0">'
            f'<testcase classname="{runner.TEST_CLASS}" '
            f'name="{runner.TEST_NAME}"><failure{failure_type}>'
            f'{body}</failure></testcase></testsuite>'
        )

    @staticmethod
    def _aggregate(xml):
        return (
            '<testsuites tests="1" skipped="0" failures="1" errors="0">'
            f'{xml}</testsuites>'
        )

    def test_owned_host_package_versions_are_bounded_and_explicit(self):
        values = {
            "RDP_ACCEPTANCE_WINPR_PACKAGE_VERSION": "3.8.0+dfsg-3build3",
            "RDP_ACCEPTANCE_XINPUT_PACKAGE_VERSION": "1.6.4-1build1",
            "RDP_ACCEPTANCE_XORG_CORE_PACKAGE_VERSION": "2:21.1.12-1ubuntu1.6",
            "RDP_ACCEPTANCE_XORG_DUMMY_PACKAGE_VERSION": "1:0.4.0-1build1",
        }
        with mock.patch.dict(os.environ, values, clear=False):
            versions = runner.fixture_package_versions()
        self.assertEqual(
            versions,
            {
                "winpr3-utils": "3.8.0+dfsg-3build3",
                "xinput": "1.6.4-1build1",
                "xserver-xorg-core": "2:21.1.12-1ubuntu1.6",
                "xserver-xorg-video-dummy": "1:0.4.0-1build1",
            },
        )
        receipt = runner.acceptance_receipt(
            versions,
            revision="a" * 40,
            package_digest="b" * 64,
            channel_evidence=CHANNEL_EVIDENCE,
        )
        self.assertEqual(receipt["ownedHostPackages"], versions)
        self.assertEqual(receipt["sourceRevision"], "a" * 40)
        self.assertEqual(receipt["packageReceiptSha256"], "b" * 64)
        self.assertEqual(receipt["scope"], "ownedShadowChannels")
        self.assertEqual(receipt["ownedShadowFixture"], {
            "version": runner.SHADOW_SOURCE_VERSION,
            "sourceCommit": runner.SHADOW_SOURCE_COMMIT,
            "sourceArchiveSha256": runner.SHADOW_SOURCE_SHA256,
            "patchSha256": runner.SHADOW_PATCH_SHA256,
        })
        self.assertEqual(receipt["evidence"]["rdpKeyEffect"], {
            "usbHidUsage": "KeyA", "xi2PressRelease": True,
        })
        self.assertEqual(receipt["evidence"]["frameAcknowledgementsAtLeast"], 2)
        self.assertEqual(receipt["evidence"]["hostDrivenFramebufferResize"], {
            "width": 1024, "height": 768, "nonzero": True,
        })
        self.assertEqual(receipt["evidence"]["channels"], CHANNEL_EVIDENCE)
        self.assertEqual(receipt["unsupportedOrUnproven"], [
            "ime", "remoteToClientClipboard",
        ])
        self.assertEqual(
            {key: receipt[key] for key in ("tests", "skipped", "failures", "errors")},
            {"tests": 1, "skipped": 0, "failures": 0, "errors": 0},
        )
        for invalid in ("", "(none)", "version with spaces", "x" * 129):
            values["RDP_ACCEPTANCE_WINPR_PACKAGE_VERSION"] = invalid
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
                    channel_evidence=CHANNEL_EVIDENCE,
                )
        with self.assertRaises(runner.AcceptanceFailure):
            runner.acceptance_receipt(
                versions,
                revision="a" * 40,
                package_digest="b" * 64,
                channel_evidence={**CHANNEL_EVIDENCE, "disabledClipboardTransfers": 1},
            )

    def test_xi2_witness_requires_one_exact_a_press_release_pair(self):
        witness = runner.Xi2KeyWitness()
        for line in (
            "EVENT type 17 (RawMotion)",
            "    detail: 38",
            "EVENT type 13 (RawKeyPress)",
            "    detail: 39",
            "EVENT type 13 (RawKeyPress)",
            "    detail: 38",
        ):
            witness.feed_bytes(line.encode("ascii"))
        self.assertFalse(witness.complete)
        witness.feed_bytes(b"EVENT type 14 (RawKeyRelease)")
        witness.feed_bytes(b"    detail: 38")
        self.assertTrue(witness.complete)

        for lines in (
            ("EVENT type 14 (RawKeyRelease)", "    detail: 38"),
            (
                "EVENT type 13 (RawKeyPress)", "    detail: 38",
                "EVENT type 13 (RawKeyPress)", "    detail: 38",
            ),
        ):
            invalid = runner.Xi2KeyWitness()
            with self.assertRaisesRegex(
                runner.BaselineFailure, "owned XI2 key witness",
            ):
                for line in lines:
                    invalid.feed_bytes(line.encode("ascii"))

    def test_xi2_witness_ignores_non_ascii_unrelated_lines_but_rejects_relevant_malformed_bytes(self):
        witness = runner.Xi2KeyWitness()
        witness.feed_bytes(b"\xe2\x8e\xa1 Virtual core keyboard id=3")
        witness.feed_bytes(b"EVENT type 13 (RawKeyPress)")
        witness.feed_bytes(b"    detail: 38")
        witness.feed_bytes(b"EVENT type 14 (RawKeyRelease)")
        witness.feed_bytes(b"    detail: 38")
        self.assertTrue(witness.complete)

        for malformed in (
            b"EVENT type \xff (RawKeyPress)",
            b"    detail:\xff38",
        ):
            with self.assertRaisesRegex(
                runner.BaselineFailure, "owned XI2 key witness was malformed",
            ):
                runner.Xi2KeyWitness().feed_bytes(malformed)

        stale = runner.Xi2KeyWitness()
        stale.feed_bytes(b"EVENT type 13 (RawKeyPress)")
        with self.assertRaises(runner.BaselineFailure):
            stale.feed_bytes(b"    detail:\xff38")
        stale.feed_bytes(b"    detail: 38")
        self.assertFalse(stale.complete)

    def test_outer_shadow_runner_ignores_unrelated_non_ascii_xi2_and_observes_exact_pair(self):
        class Process:
            def __init__(self, *, stdout=None, finish_after=None):
                self.stdout = stdout
                self.finish_after = finish_after
                self.polls = 0

            def poll(self):
                self.polls += 1
                if self.finish_after is not None and self.polls >= self.finish_after:
                    return 0
                return None

        class Selector:
            def __init__(self):
                self.index = 0

            def register(self, *_args):
                pass

            def select(self, *, timeout):
                values = (
                    SimpleNamespace(fd=7, data="xi2"),
                    SimpleNamespace(fd=8, data="phase"),
                    SimpleNamespace(fd=8, data="phase"),
                )
                value = values[min(self.index, len(values) - 1)]
                self.index += 1
                return [(value, None)]

            def close(self):
                pass

        shadow = Process(stdout=object())
        xinput = Process(stdout=object())
        gradle = Process(finish_after=4)
        output = iter((
            b"\xe2\x8e\xa1 Virtual core keyboard id=3\n"
            b"EVENT type 13 (RawKeyPress)\n    detail: 38\n"
            b"EVENT type 14 (RawKeyRelease)\n    detail: 38\n",
            runner._CHANNEL_PHASE_DISP,
            runner._CHANNEL_PHASE_CLIP,
        ))
        evidence = CHANNEL_EVIDENCE.copy()
        with tempfile.TemporaryDirectory() as temporary:
            with (
                mock.patch.object(
                    runner,
                    "_start_owned_shadow",
                    return_value=(
                        shadow, 8, "c" * 64, 9,
                        Path(temporary) / "shadow.log", 0,
                    ),
                ),
                mock.patch.object(runner.subprocess, "Popen", side_effect=[xinput, gradle]),
                mock.patch.object(runner.selectors, "DefaultSelector", return_value=Selector()),
                mock.patch.object(runner.os, "read", side_effect=lambda _fd, _size: next(output)),
                mock.patch.object(runner, "_resize_owned_display") as resize,
                mock.patch.object(runner, "_mark_clipboard_effect") as marker,
                mock.patch.object(runner, "_channel_evidence", return_value=evidence),
                mock.patch.object(runner, "_append_private_log", return_value=0),
                mock.patch.object(runner, "_server_resize_requested", return_value=True),
                mock.patch.object(runner, "_stop_owned_process"),
                mock.patch.object(runner.os, "close"),
            ):
                self.assertEqual(
                    runner._run_owned_shadow_baseline(
                        ["owned-gradle"], runner_temp=Path(temporary),
                        diagnostic_nonce="d" * 64,
                    ),
                    (0, evidence, None, None),
                )
        resize.assert_called_once_with()
        marker.assert_called_once_with()

    def test_terminal_channel_witness_requires_enabled_effects_and_disabled_zero_transfer(self):
        enabled = {
            "schemaVersion": 1,
            "clipboardEffect": True,
            "displayEffect": True,
            "formatLists": 1,
            "dataRequests": 1,
            "dataResponses": 1,
            "emptyResponses": 0,
            "displayLayouts": 1,
            "channelErrors": 0,
        }
        disabled = {
            "schemaVersion": 1,
            "clipboardEffect": False,
            "displayEffect": False,
            "formatLists": 0,
            "dataRequests": 0,
            "dataResponses": 0,
            "emptyResponses": 0,
            "displayLayouts": 0,
            "channelErrors": 0,
        }
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary) / "witness"
            Path(f"{base}.1").touch()
            Path(f"{base}.2").touch()
            with mock.patch.object(
                runner, "read_lifetimes",
                return_value={"schemaVersion": 1, "enabled": enabled, "disabled": disabled},
            ):
                self.assertEqual(runner._channel_evidence(base), CHANNEL_EVIDENCE_BASE)
            for bad in (
                {**enabled, "clipboardEffect": False},
                {**disabled, "dataRequests": 1},
                {**disabled, "channelErrors": 1},
            ):
                pair = (
                    {"schemaVersion": 1, "enabled": bad, "disabled": disabled}
                    if bad.get("formatLists") else
                    {"schemaVersion": 1, "enabled": enabled, "disabled": bad}
                )
                with mock.patch.object(runner, "read_lifetimes", return_value=pair):
                    with self.assertRaises(runner.BaselineFailure):
                        runner._channel_evidence(base)

    def test_owned_shadow_process_uses_exact_binary_sam_pipe_and_two_witness_base(self):
        def portable_owned_pipe2(flags):
            self.assertEqual(flags, os.O_CLOEXEC | os.O_NONBLOCK)
            read_fd, write_fd = os.pipe()
            for descriptor in (read_fd, write_fd):
                os.set_inheritable(descriptor, False)
                os.set_blocking(descriptor, False)
            return read_fd, write_fd

        process = SimpleNamespace(
            poll=lambda: None,
            stdout=SimpleNamespace(fileno=lambda: 123),
        )
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            source = root / "source"
            source.mkdir(mode=0o700)
            build = root / "build"
            build.mkdir(mode=0o700)
            binary = build / runner.SHADOW_CLI_RELATIVE
            binary.parent.mkdir(parents=True)
            binary.write_bytes(b"owned-shadow-binary")
            binary.chmod(0o700)
            sam = root / "larenor-rdp.sam"
            sam.write_bytes(b"owned-private-sam")
            sam.chmod(0o600)
            witness = root / "terminal-witness"
            with (
                mock.patch.dict(
                    os.environ,
                    {
                        "RDP_ACCEPTANCE_SHADOW_BINARY": str(binary),
                        "RDP_ACCEPTANCE_SHADOW_SOURCE": str(source),
                        "RDP_ACCEPTANCE_SHADOW_BUILD": str(build),
                    },
                    clear=False,
                ),
                mock.patch.object(runner, "_shadow_port_open", return_value=False),
                mock.patch.object(runner, "_wait_shadow_ready", return_value=0) as ready,
                mock.patch.object(runner, "verify_patched_source") as verify_source,
                mock.patch.object(runner.subprocess, "Popen", return_value=process) as popen,
                mock.patch.object(runner.os, "set_blocking"),
                mock.patch.object(
                    runner.os, "pipe2", side_effect=portable_owned_pipe2, create=True,
                ) as pipe2,
            ):
                (
                    returned, read_fd, digest, log_fd, log_path, log_size,
                ) = runner._start_owned_shadow(root, witness)
            try:
                self.assertIs(returned, process)
                self.assertEqual(log_path, root / "shadow.log")
                self.assertEqual(log_size, 0)
                self.assertEqual(os.fstat(log_fd).st_mode & 0o777, 0o600)
                self.assertEqual(
                    digest, hashlib.sha256(b"owned-shadow-binary").hexdigest(),
                )
                command = popen.call_args.args[0]
                self.assertEqual(command, [
                    str(binary), "/port:3390", "/sec:nla", f"/sam-file:{sam}",
                ])
                environment = popen.call_args.kwargs["env"]
                self.assertEqual(environment["LARENOR_F62_CHANNEL_WITNESS"], str(witness))
                self.assertEqual(environment["LARENOR_F62_EXPECT_WIDTH"], "1024")
                self.assertEqual(environment["LARENOR_F62_EXPECT_HEIGHT"], "768")
                self.assertEqual(
                    popen.call_args.kwargs["pass_fds"],
                    (int(environment["LARENOR_F62_CHANNEL_PHASE_FD"]),),
                )
                ready.assert_called_once_with(process, log_fd)
                verify_source.assert_called_once_with(source)
                pipe2.assert_called_once_with(os.O_CLOEXEC | os.O_NONBLOCK)
            finally:
                os.close(read_fd)
                os.close(log_fd)

            alias = root / "shadow-alias"
            alias.symlink_to(binary)
            with self.assertRaises(runner.BaselineFailure):
                runner._owned_regular(alias, executable=True)

    def test_private_shadow_log_exposes_only_exact_resize_request_boolean(self):
        with tempfile.TemporaryDirectory() as temporary:
            log = Path(temporary) / "shadow.log"
            log.write_bytes(
                b"[INFO][com.freerdp.server.shadow.client] - Client private-host "
                b"resize requested (1024x768@180)\nprivate credential text\n"
            )
            log.chmod(0o600)
            self.assertTrue(runner._server_resize_requested(log))
            log.write_bytes(b"resize requested (1280x800@180)\n")
            self.assertFalse(runner._server_resize_requested(log))
            log.chmod(0o644)
            with self.assertRaises(runner.BaselineFailure):
                runner._server_resize_requested(log)

    def test_failure_receipt_accepts_only_boolean_resize_diagnostic(self):
        base = {
            "code": "instrumentation_test_failure",
            "exceptionType": "java.lang.AssertionError",
            "frames": [],
            "counts": {"tests": 1, "skipped": 0, "failures": 1, "errors": 0},
        }
        receipt = runner.failure_receipt(
            {},
            revision="a" * 40,
            package_digest="b" * 64,
            diagnostic={**base, "serverResizeRequested": True},
        )
        self.assertIs(receipt["diagnostic"]["serverResizeRequested"], True)
        for invalid in ("true", 1, None):
            diagnostic = {**base, "serverResizeRequested": invalid}
            with self.assertRaises(runner.AcceptanceFailure):
                runner.failure_receipt(
                    {}, revision="a" * 40, package_digest="b" * 64,
                    diagnostic=diagnostic,
                )

    def test_failure_receipt_accepts_only_fixed_private_test_lifecycle_stage(self):
        base = {
            "code": "instrumentation_test_failure",
            "exceptionType": "unclassified",
            "frames": [],
            "counts": {"tests": 1, "skipped": 0, "failures": 1, "errors": 0},
        }
        receipt = runner.failure_receipt(
            {}, revision="a" * 40, package_digest="b" * 64,
            diagnostic={**base, "testLifecycleStage": "initialFrameWait"},
        )
        self.assertEqual(
            receipt["diagnostic"]["testLifecycleStage"], "initialFrameWait",
        )
        for invalid in ("", "private-host", 1, None):
            with self.assertRaises(runner.AcceptanceFailure):
                runner.failure_receipt(
                    {}, revision="a" * 40, package_digest="b" * 64,
                    diagnostic={**base, "testLifecycleStage": invalid},
                )

    def test_private_test_lifecycle_stage_is_bounded_allowlisted_and_removed(self):
        nonce = "d" * 64
        completed = [
            SimpleNamespace(returncode=0, stdout=b"resizedFrameWait"),
            SimpleNamespace(returncode=0, stdout=b""),
        ]
        with (
            mock.patch.object(runner, "_adb_path", return_value=Path("/sdk/adb")),
            mock.patch.object(runner.subprocess, "run", side_effect=completed) as run,
        ):
            self.assertEqual(
                runner._read_test_lifecycle_stage(nonce), "resizedFrameWait",
            )
        self.assertEqual(run.call_count, 2)
        self.assertEqual(
            run.call_args_list[0].args[0],
            [
                "/sdk/adb", "exec-out", "run-as", runner._TEST_PACKAGE,
                "dd", f"if=files/f62-owned-stage-{nonce}", "bs=128", "count=1",
            ],
        )
        self.assertEqual(
            run.call_args_list[1].args[0],
            [
                "/sdk/adb", "shell", "run-as", runner._TEST_PACKAGE,
                "rm", "-f", f"files/f62-owned-stage-{nonce}",
                f"files/f62-owned-stage-{nonce}.new",
                f"files/f62-owned-stage-{nonce}.bak",
            ],
        )
        for raw in (b"private-host", b"resizedFrameWait\nsecret", b"\xff"):
            with (
                mock.patch.object(runner, "_adb_path", return_value=Path("/sdk/adb")),
                mock.patch.object(
                    runner.subprocess, "run",
                    side_effect=[
                        SimpleNamespace(returncode=0, stdout=raw),
                        SimpleNamespace(returncode=0, stdout=b""),
                    ],
                ),
            ):
                self.assertIsNone(runner._read_test_lifecycle_stage(nonce))
        with (
            mock.patch.object(runner, "_adb_path", return_value=Path("/sdk/adb")),
            mock.patch.object(
                runner.subprocess, "run",
                side_effect=[
                    runner.subprocess.TimeoutExpired(["adb"], 5),
                    SimpleNamespace(returncode=0, stdout=b""),
                ],
            ) as timed_out,
        ):
            self.assertIsNone(runner._read_test_lifecycle_stage(nonce))
        self.assertEqual(timed_out.call_count, 2)
        self.assertIs(timed_out.call_args_list[0].kwargs["stderr"], runner.subprocess.DEVNULL)
        self.assertIs(timed_out.call_args_list[1].kwargs["stdout"], runner.subprocess.DEVNULL)
        self.assertIsNone(runner._read_test_lifecycle_stage("not-a-nonce"))

    def test_android_test_lifecycle_markers_match_the_public_fixed_enum(self):
        source = (
            runner.ROOT
            / "android/app/src/freerdpAndroidTest/kotlin/com/ersingundem/larenor/rdp"
            / "RdpPackagedHostAcceptanceTest.kt"
        ).read_text()
        test_body = source.split(
            "private fun assertDiagnosticFailuresAreSecondary", 1,
        )[0]
        observed = re.findall(r'diagnostic\.enter\("([A-Za-z]+)"\)', test_body)
        self.assertEqual(observed, list(runner._TEST_LIFECYCLE_STAGES))
        self.assertIn('Regex("[0-9a-f]{64}")', source)
        self.assertIn('AtomicFile(File(context.filesDir, "f62-owned-stage-$nonce"))', source)
        self.assertIn("file.failWrite(stream)", source)
        self.assertIn("runCatching { storage.write(stage) }", source)
        self.assertIn("runCatching { storage.remove() }", source)

    def test_owned_resize_requires_xrandr_and_exact_xdpyinfo_readback(self):
        completed = [
            SimpleNamespace(
                returncode=0,
                stdout=(
                    b"Screen 0: minimum 64 x 64, current 1280 x 800\n"
                    b"DUMMY0 connected primary 1280x800+0+0 0mm x 0mm\n"
                ),
            ),
            SimpleNamespace(returncode=0, stdout=b""),
            SimpleNamespace(
                returncode=0,
                stdout=b"DUMMY0 connected primary 1024x768+0+0 0mm x 0mm\n",
            ),
            SimpleNamespace(
                returncode=0,
                stdout=(
                    b"name of display: :99\n"
                    b"  dimensions:    1024x768 pixels (271x203 millimeters)\n"
                ),
            ),
        ]
        with (
            mock.patch.dict(
                os.environ, {"RDP_ACCEPTANCE_XORG_OUTPUT": "DUMMY0"}, clear=False,
            ),
            mock.patch.object(
                runner.subprocess, "run", side_effect=completed,
            ) as process,
        ):
            runner._resize_owned_display()
        self.assertEqual(
            process.call_args_list[0].args[0],
            ["/usr/bin/xrandr", "--query"],
        )
        self.assertEqual(
            process.call_args_list[1].args[0],
            [
                "/usr/bin/xrandr", "--output", "DUMMY0",
                "--mode", "1024x768", "--fb", "1024x768",
            ],
        )
        self.assertEqual(
            process.call_args_list[2].args[0], ["/usr/bin/xrandr", "--query"],
        )
        self.assertEqual(process.call_args_list[3].args[0], ["/usr/bin/xdpyinfo"])
        self.assertEqual(process.call_args_list[0].kwargs["env"]["DISPLAY"], ":99")

        with (
            mock.patch.dict(
                os.environ, {"RDP_ACCEPTANCE_XORG_OUTPUT": "DUMMY0"}, clear=False,
            ),
            mock.patch.object(
                runner.subprocess,
                "run",
                side_effect=[
                    completed[0],
                    SimpleNamespace(returncode=0, stdout=b""),
                    completed[2],
                    SimpleNamespace(
                        returncode=0,
                        stdout=b"  dimensions:    1280x800 pixels\n",
                    ),
                ],
            ),
        ):
            with self.assertRaisesRegex(
                runner.BaselineFailure, "resize was not observed",
            ):
                runner._resize_owned_display()

    def test_owned_resize_rejects_ambiguous_or_replaced_xorg_output(self):
        query = SimpleNamespace(
            returncode=0,
            stdout=(
                b"DUMMY0 connected 1280x800+0+0 0mm x 0mm\n"
                b"DUMMY1 connected 1024x768+0+0 0mm x 0mm\n"
            ),
        )
        with (
            mock.patch.dict(
                os.environ, {"RDP_ACCEPTANCE_XORG_OUTPUT": "DUMMY0"}, clear=False,
            ),
            mock.patch.object(runner.subprocess, "run", return_value=query) as process,
            self.assertRaisesRegex(
                runner.BaselineFailure, "active output was ambiguous",
            ),
        ):
            runner._resize_owned_display()
        process.assert_called_once()

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
                valid.replace('</testsuite>', '<testsuite/></testsuite>'),
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

    def test_single_android_aggregate_suite_preserves_exact_success_identity(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            report = directory / "TEST-device.xml"
            suite = (
                '<testsuite tests="1" skipped="0" failures="0" errors="0">'
                f'<testcase classname="{runner.TEST_CLASS}" '
                f'name="{runner.TEST_NAME}"/></testsuite>'
            )
            aggregate = (
                '<testsuites tests="1" skipped="0" failures="0" errors="0">'
                f'{suite}</testsuites>'
            )
            report.write_text(aggregate)
            self.assertEqual(runner.verify_reports(directory), report)

            for invalid in (
                aggregate.replace('tests="1"', 'tests="2"', 1),
                aggregate.replace('</testsuites>', f'{suite}</testsuites>'),
                aggregate.replace('<testsuite ', '<unexpected ', 1)
                    .replace('</testsuite>', '</unexpected>', 1),
            ):
                report.write_text(invalid)
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
                    "winpr3-utils": "3.8.0+dfsg-3build3",
                    "xinput": "1.6.4-1build1",
                },
                revision="a" * 40,
                package_digest="b" * 64,
                channel_evidence=CHANNEL_EVIDENCE,
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
                "winpr3-utils": "3.8.0+dfsg-3build3",
                "xinput": "1.6.4-1build1",
            }
            with (
                mock.patch.object(runner, "source_revision", return_value="a" * 40),
                mock.patch.object(
                    runner, "package_receipt_digest", return_value="b" * 64
                ),
            ):
                path = runner.publish_public_receipt(
                    report, root, versions, CHANNEL_EVIDENCE,
                )
            self.assertFalse(report.exists())
            self.assertEqual(path.parent.stat().st_mode & 0o777, 0o700)
            self.assertEqual(
                json.loads(path.read_text()),
                runner.acceptance_receipt(
                    versions,
                    revision="a" * 40,
                    package_digest="b" * 64,
                    channel_evidence=CHANNEL_EVIDENCE,
                ),
            )

    def test_failure_diagnostic_exposes_only_known_type_and_owned_frames(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary).resolve()
            report = directory / "TEST-device.xml"
            secret = "dispose-password-should-never-publish"
            report.write_text(self._failure_xml(body=(
                "java.lang.AssertionError: " + secret + "\n"
                " at com.ersingundem.larenor.rdp.RdpPackagedHostAcceptanceTest."
                "nlaShadowBaselineProvesPinnedFramesKeyEffectResizeAndCleanClose("
                "RdpPackagedHostAcceptanceTest.kt:92)\n"
                " at unowned.example.Client.run(/home/runner/Secret.kt:44)\n"
                " at com.ersingundem.larenor.rdp.Forged.run(Forged.kt:7)\n"
            )))

            diagnostic = runner.failure_diagnostic(directory)

            self.assertEqual(diagnostic, {
                "code": "instrumentation_test_failure",
                "exceptionType": "java.lang.AssertionError",
                "frames": [{
                    "file": "RdpPackagedHostAcceptanceTest.kt", "line": 92,
                }],
                "counts": {
                    "tests": 1, "skipped": 0, "failures": 1, "errors": 0,
                },
            })
            public = json.dumps(diagnostic)
            self.assertNotIn(secret, public)
            self.assertNotIn("/home/runner", public)
            self.assertNotIn("Forged.kt", public)
            self.assertNotIn("acceptanceStage", diagnostic)

    def test_post_resize_failure_exposes_only_fixed_source_bound_stage(self):
        stage_type = (
            "com.ersingundem.larenor.rdp."
            "RdpOwnedResizedFrameWaitFailure"
        )
        body = (
            stage_type + ": private fixture and pixel material\n"
            " at com.ersingundem.larenor.rdp.RdpPackagedHostAcceptanceTest."
            "nlaShadowBaselineProvesPinnedFramesKeyEffectResizeAndCleanClose("
            "RdpPackagedHostAcceptanceTest.kt:131)\n"
            "Caused by: java.lang.AssertionError: private host identity\n"
        )
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            (directory / "TEST-device.xml").write_text(
                # ddmlib's connected-test XmlTestRunListener serializes only
                # the stack trace text inside <failure>; it emits no type
                # attribute. The first trace header therefore carries the
                # concrete throwable class.
                self._failure_xml(exception_type=None, body=body),
            )

            diagnostic = runner.failure_diagnostic(directory)

        self.assertEqual(diagnostic["exceptionType"], stage_type)
        self.assertEqual(diagnostic["acceptanceStage"], "resizedFrameWait")
        self.assertEqual(diagnostic["frames"], [{
            "file": "RdpPackagedHostAcceptanceTest.kt", "line": 131,
        }])
        serialized = json.dumps(diagnostic)
        self.assertNotIn("private fixture", serialized)
        self.assertNotIn("private host", serialized)

    def test_post_resize_stage_rejects_injected_type_text_identity_and_source(self):
        stage_type = (
            "com.ersingundem.larenor.rdp."
            "RdpOwnedResizedFrameAckFailure"
        )
        valid_frame = (
            " at com.ersingundem.larenor.rdp.RdpPackagedHostAcceptanceTest."
            "nlaShadowBaselineProvesPinnedFramesKeyEffectResizeAndCleanClose("
            "RdpPackagedHostAcceptanceTest.kt:139)\n"
        )
        cases = (
            (
                "java.lang.AssertionError",
                stage_type + ": injected only in a message\n" + valid_frame,
                None,
            ),
            (
                None,
                "java.lang.AssertionError: " + stage_type + " injected in message\n"
                + valid_frame,
                None,
            ),
            (
                stage_type,
                stage_type + "\n at private.injected.Client.run(Secret.kt:1)\n",
                None,
            ),
            (
                stage_type,
                stage_type + "\n" + valid_frame,
                "anotherMethod",
            ),
        )
        for exception_type, body, replacement in cases:
            with self.subTest(exception_type=exception_type, replacement=replacement):
                with tempfile.TemporaryDirectory() as temporary:
                    directory = Path(temporary)
                    xml = self._failure_xml(
                        exception_type=exception_type, body=body,
                    )
                    if replacement is not None:
                        xml = xml.replace(runner.TEST_NAME, replacement, 1)
                    (directory / "TEST-device.xml").write_text(xml)
                    diagnostic = runner.failure_diagnostic(directory)
                self.assertNotIn("acceptanceStage", diagnostic)
                if exception_type == stage_type:
                    self.assertEqual(diagnostic["exceptionType"], "unclassified")

    def test_failure_receipt_requires_exact_stage_type_pair(self):
        base = {
            "code": "instrumentation_test_failure",
            "exceptionType": (
                "com.ersingundem.larenor.rdp."
                "RdpOwnedResizedFrameAckFailure"
            ),
            "frames": [{
                "file": "RdpPackagedHostAcceptanceTest.kt", "line": 139,
            }],
            "counts": {
                "tests": 1, "skipped": 0, "failures": 1, "errors": 0,
            },
            "acceptanceStage": "resizedFrameAck",
        }
        receipt = runner.failure_receipt(
            {}, revision="a" * 40, package_digest="b" * 64,
            diagnostic=base,
        )
        self.assertEqual(
            receipt["diagnostic"]["acceptanceStage"], "resizedFrameAck",
        )
        for changed in (
            {**base, "acceptanceStage": "resizedFramePixels"},
            {**base, "acceptanceStage": "privateInjectedStage"},
            {**base, "exceptionType": "java.lang.AssertionError"},
            {**base, "code": "instrumentation_test_error"},
        ):
            with self.assertRaises(runner.AcceptanceFailure):
                runner.failure_receipt(
                    {}, revision="a" * 40, package_digest="b" * 64,
                    diagnostic=changed,
                )

    def test_android_aggregate_failure_exposes_only_bounded_probe_outcome(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary).resolve()
            report = directory / "TEST-device.xml"
            secret = "private-host-and-certificate-material"
            body = (
                "RdpNativeFailure(engineUnavailable): " + secret + "\n"
                " at com.ersingundem.larenor.rdp.packaged.RdpPackagedRuntime."
                "inspect(RdpPackagedRuntime.kt:87)\n"
                "Caused by: RdpProbeOutcome(connectionFailureBeforeCertificate)\n"
            )
            report.write_text(self._aggregate(self._failure_xml(body=body)))

            diagnostic = runner.failure_diagnostic(directory)

            self.assertEqual(diagnostic, {
                "code": "instrumentation_test_failure",
                "exceptionType": "java.lang.AssertionError",
                "frames": [{"file": "RdpPackagedRuntime.kt", "line": 87}],
                "counts": {
                    "tests": 1, "skipped": 0, "failures": 1, "errors": 0,
                },
                "probeOutcome": "connectionFailureBeforeCertificate",
            })
            public = runner.failure_receipt(
                {"winpr3-utils": "3.32.0"},
                revision="a" * 40,
                package_digest="b" * 64,
                diagnostic=diagnostic,
            )
            self.assertEqual(
                public["diagnostic"]["probeOutcome"],
                "connectionFailureBeforeCertificate",
            )
            self.assertNotIn(secret, json.dumps(public))

    def test_probe_outcome_requires_one_known_marker_and_owned_runtime_frame(self):
        self.assertEqual(runner._PROBE_OUTCOMES, {
            "timeout",
            "connectionFailureBeforeCertificate",
            "certificateCallbackMissingPem",
            "certificateParseFailed",
        })
        base = (
            "java.lang.AssertionError\n"
            " at com.ersingundem.larenor.rdp.packaged.RdpPackagedRuntime."
            "inspect(RdpPackagedRuntime.kt:87)\n"
        )
        for suffix in (
            "Caused by: RdpProbeOutcome(privateRawFailure)\n",
            "Caused by: RdpProbeOutcome(timeout)\n"
            "Caused by: RdpProbeOutcome(certificateParseFailed)\n",
        ):
            with tempfile.TemporaryDirectory() as temporary:
                directory = Path(temporary)
                (directory / "TEST-device.xml").write_text(
                    self._failure_xml(body=base + suffix),
                )
                diagnostic = runner.failure_diagnostic(directory)
                self.assertNotIn("probeOutcome", diagnostic)

        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            body = (
                "java.lang.AssertionError\n"
                " at com.ersingundem.larenor.rdp.RdpPackagedHostAcceptanceTest."
                "run(RdpPackagedHostAcceptanceTest.kt:43)\n"
                "Caused by: RdpProbeOutcome(timeout)\n"
            )
            (directory / "TEST-device.xml").write_text(
                self._failure_xml(body=body),
            )
            self.assertNotIn(
                "probeOutcome", runner.failure_diagnostic(directory),
            )

        for outcome in sorted(runner._PROBE_OUTCOMES):
            with tempfile.TemporaryDirectory() as temporary:
                directory = Path(temporary)
                (directory / "TEST-device.xml").write_text(
                    self._failure_xml(
                        body=base + f"Caused by: RdpProbeOutcome({outcome})\n",
                    ),
                )
                self.assertEqual(
                    runner.failure_diagnostic(directory)["probeOutcome"],
                    outcome,
                )

    def test_failure_diagnostic_maps_unknown_or_unusable_reports_to_static_codes(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary).resolve()
            self.assertEqual(
                runner.failure_diagnostic(directory)["code"],
                "instrumentation_report_missing",
            )
            report = directory / "TEST-device.xml"
            report.write_text("<broken")
            self.assertEqual(
                runner.failure_diagnostic(directory)["code"],
                "instrumentation_report_malformed",
            )
            report.write_text(self._failure_xml(
                exception_type="private.SecretException",
                body="private.SecretException: token=do-not-publish",
            ))
            diagnostic = runner.failure_diagnostic(directory)
            self.assertEqual(diagnostic["exceptionType"], "unclassified")
            self.assertNotIn("SecretException", json.dumps(diagnostic))
            (directory / "TEST-stale.xml").write_text(
                self._failure_xml(body="java.lang.AssertionError"),
            )
            self.assertEqual(
                runner.failure_diagnostic(directory)["code"],
                "instrumentation_report_ambiguous",
            )

    def test_malformed_report_shape_exposes_only_bounded_structure(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            report = directory / "TEST-device.xml"
            report.write_text(
                '<testsuites tests="1" skipped="0" failures="1" errors="0">'
                '<privateSecret/><testsuite/><testsuite/></testsuites>',
            )
            diagnostic = runner.failure_diagnostic(directory)
            self.assertEqual(diagnostic, {
                "code": "instrumentation_report_malformed",
                "exceptionType": "unclassified",
                "frames": [],
                "reportShape": "aggregate",
                "childSuiteCount": 2,
            })
            public = runner.failure_receipt(
                {}, revision="a" * 40, package_digest="b" * 64,
                diagnostic=diagnostic,
            )
            self.assertNotIn("privateSecret", json.dumps(public))

            report.write_text(
                '<privateSecret tests="1" skipped="0" failures="1" errors="0"/>',
            )
            diagnostic = runner.failure_diagnostic(directory)
            self.assertEqual(diagnostic["reportShape"], "unsupported")
            self.assertEqual(diagnostic["childSuiteCount"], 0)
            self.assertNotIn("privateSecret", json.dumps(diagnostic))

    def test_packaged_production_frame_is_retained_without_message(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary).resolve()
            (directory / "TEST-device.xml").write_text(self._failure_xml(body=(
                "java.lang.IllegalStateException: private-password\n"
                " at com.ersingundem.larenor.rdp.packaged.RdpPackagedRuntime."
                "open(RdpPackagedRuntime.kt:112)"
            )))
            diagnostic = runner.failure_diagnostic(directory)
            self.assertEqual(diagnostic["frames"], [{
                "file": "RdpPackagedRuntime.kt", "line": 112,
            }])
            self.assertNotIn("private-password", json.dumps(diagnostic))

    def test_initialization_identity_failure_keeps_owned_frame_but_cannot_pass_acceptance(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary).resolve()
            secret = "private-initialization-method-and-message"
            report = directory / "TEST-device.xml"
            report.write_text(self._failure_xml(body=(
                "java.lang.RuntimeException: " + secret + "\n"
                " at com.ersingundem.larenor.rdp.packaged.RdpPackagedRuntime."
                "open(RdpPackagedRuntime.kt:112)"
            )).replace(runner.TEST_NAME, secret))
            diagnostic = runner.failure_diagnostic(directory)
            self.assertEqual(diagnostic["code"], "instrumentation_report_identity_mismatch")
            self.assertEqual(diagnostic["identity"], {
                "suiteExpected": True, "countsExpected": True, "caseCount": 1,
                "classExpected": True, "methodExpected": False,
            })
            self.assertEqual(diagnostic["frames"], [{
                "file": "RdpPackagedRuntime.kt", "line": 112,
            }])
            self.assertNotIn(secret, json.dumps(diagnostic))
            with self.assertRaises(runner.AcceptanceFailure):
                runner.verify_reports(directory)
            public = runner.failure_receipt(
                {"winpr3-utils": "3.32.0"},
                revision="a" * 40, package_digest="b" * 64, diagnostic=diagnostic)
            self.assertEqual(public["result"], "failed")
            for bad in (
                {**diagnostic, "identity": {**diagnostic["identity"], "methodExpected": secret}},
                {**diagnostic, "counts": {**diagnostic["counts"], "tests": 1025}},
                {**diagnostic, "identity": {**diagnostic["identity"], "caseCount": True}},
            ):
                with self.assertRaises(runner.AcceptanceFailure):
                    runner.failure_receipt({}, revision="a" * 40, package_digest="b" * 64,
                                           diagnostic=bad)

    def test_native_constructor_failure_retains_class_and_location_without_library_path(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary).resolve()
            (directory / "TEST-device.xml").write_text(self._failure_xml(
                exception_type="java.lang.UnsatisfiedLinkError",
                body=("java.lang.UnsatisfiedLinkError: /data/private/lib-secret.so\n"
                      " at com.ersingundem.larenor.rdp.packaged.RdpPackagedRuntime."
                      "&lt;init&gt;(RdpPackagedRuntime.kt:62)"),
            ).replace(runner.TEST_NAME, "initializationError"))
            diagnostic = runner.failure_diagnostic(directory)
            self.assertEqual(diagnostic["exceptionType"], "java.lang.UnsatisfiedLinkError")
            self.assertEqual(diagnostic["frames"], [{"file": "RdpPackagedRuntime.kt", "line": 62}])
            self.assertNotIn("lib-secret", json.dumps(diagnostic))

    def test_failure_frames_are_deduplicated_bounded_and_require_regular_xml(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary).resolve()
            report = directory / "TEST-device.xml"
            lines = [
                " at com.ersingundem.larenor.rdp.RdpPackagedHostAcceptanceTest."
                f"run(RdpPackagedHostAcceptanceTest.kt:{line})"
                for line in range(1, 11)
            ]
            lines.append(lines[0])
            report.write_text(self._failure_xml(body="\n".join(lines)))
            frames = runner.failure_diagnostic(directory)["frames"]
            self.assertEqual(len(frames), 8)
            self.assertEqual(frames[0], {
                "file": "RdpPackagedHostAcceptanceTest.kt", "line": 1,
            })
            self.assertEqual(frames[-1]["line"], 8)

            report.unlink()
            target = directory / "private.xml"
            target.write_text(self._failure_xml())
            report.symlink_to(target)
            self.assertEqual(
                runner.failure_diagnostic(directory)["code"],
                "instrumentation_report_malformed",
            )
            report.unlink()
            target.unlink()
            report.write_bytes(b"x" * (runner._MAX_REPORT_BYTES + 1))
            self.assertEqual(
                runner.failure_diagnostic(directory)["code"],
                "instrumentation_report_malformed",
            )
            report.write_text(
                '<!DOCTYPE x [<!ENTITY private "do-not-expand">]>'
                + self._failure_xml(body="&private;"),
            )
            self.assertEqual(
                runner.failure_diagnostic(directory)["code"],
                "instrumentation_report_malformed",
            )

    def test_failure_receipt_is_canonical_private_and_removes_raw_report(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            reports = root / "reports"
            reports.mkdir()
            report = reports / "TEST-device.xml"
            report.write_text(self._failure_xml(body=(
                "java.lang.AssertionError: private-message\n"
                " at com.ersingundem.larenor.rdp.RdpPackagedHostAcceptanceTest."
                "run(RdpPackagedHostAcceptanceTest.kt:105)"
            )))
            diagnostic = runner.failure_diagnostic(reports)
            versions = {
                "winpr3-utils": "3.8.0+dfsg-3build3",
                "xinput": "1.6.4-1build1",
            }
            with (
                mock.patch.object(runner, "source_revision", return_value="a" * 40),
                mock.patch.object(
                    runner, "package_receipt_digest", return_value="b" * 64,
                ),
            ):
                path = runner.publish_public_failure(
                    diagnostic, root, versions, reports,
                )
            payload = json.loads(path.read_text())
            self.assertEqual(payload["result"], "failed")
            self.assertEqual(payload["diagnostic"], diagnostic)
            self.assertFalse(report.exists())
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            serialized = path.read_text()
            self.assertNotIn("private-message", serialized)
            self.assertNotIn(str(root), serialized)

    def test_failure_receipt_rejects_raw_or_unowned_diagnostic_fields(self):
        versions = {
            "winpr3-utils": "3.8.0+dfsg-3build3",
        }
        for diagnostic in (
            {"code": "instrumentation_test_failure",
             "exceptionType": "java.lang.AssertionError", "frames": [],
             "message": "secret"},
            {"code": "instrumentation_test_failure",
             "exceptionType": "private.SecretException", "frames": []},
            {"code": "instrumentation_test_failure",
             "exceptionType": "java.lang.AssertionError",
             "frames": [{"file": "/tmp/Secret.kt", "line": 1}]},
            {"code": "instrumentation_test_failure",
             "exceptionType": "java.lang.AssertionError", "frames": []},
            {"code": "instrumentation_report_missing",
             "exceptionType": "unclassified", "frames": [],
             "counts": {
                 "tests": 1, "skipped": 0, "failures": 1, "errors": 0,
             }},
        ):
            with self.assertRaises(runner.AcceptanceFailure):
                runner.failure_receipt(
                    versions, revision="a" * 40, package_digest="b" * 64,
                    diagnostic=diagnostic,
                )

    def test_workflow_uploads_only_bounded_failure_json_on_failure(self):
        workflow = json.loads(
            (runner.ROOT / ".github/workflows/freerdp-android-native.yml")
            .read_text()
        )
        step = next(
            value for value in workflow["jobs"]["package"]["steps"]
            if value.get("name") == "Upload bounded native failure diagnostics"
        )
        self.assertEqual(
            step["if"],
            "failure() && matrix.abi == 'x86_64' && steps.packaged_acceptance.outcome == 'failure'",
        )
        self.assertEqual(
            step["with"]["path"],
            "${{ runner.temp }}/freerdp-public-acceptance/failure.json",
        )
        self.assertEqual(step["with"]["if-no-files-found"], "error")
        self.assertNotIn("TEST-", json.dumps(step))

    def test_failed_instrumentation_publishes_diagnostic_and_suppresses_gradle(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            reports = root / "reports"
            reports.mkdir()
            report = reports / "TEST-device.xml"
            failure_xml = self._failure_xml(body=(
                "java.lang.AssertionError: disposable-password\n"
                " at com.ersingundem.larenor.rdp.RdpPackagedHostAcceptanceTest."
                "run(RdpPackagedHostAcceptanceTest.kt:114)"
            ))

            def failed_process(*_args, **_kwargs):
                report.write_text(failure_xml)
                return 1, None, True, "initialFrameWait"
            environment = {
                "RUNNER_TEMP": str(root),
                "RDP_ACCEPTANCE_PASSWORD": "disposable-password",
                "RDP_ACCEPTANCE_WINPR_PACKAGE_VERSION": "3.8.0+dfsg-3build3",
                "RDP_ACCEPTANCE_XINPUT_PACKAGE_VERSION": "1.6.4-1build1",
                "RDP_ACCEPTANCE_XORG_CORE_PACKAGE_VERSION": "2:21.1.12-1ubuntu1.6",
                "RDP_ACCEPTANCE_XORG_DUMMY_PACKAGE_VERSION": "1:0.4.0-1build1",
            }
            with (
                mock.patch.dict(os.environ, environment, clear=False),
                mock.patch.object(runner, "REPORTS", reports),
                mock.patch.object(
                    runner, "materialized_gradle_command", return_value=["java"],
                ),
                mock.patch.object(
                    runner, "_run_owned_shadow_baseline",
                    side_effect=failed_process,
                ) as process,
                mock.patch.object(
                    runner, "_provenance", return_value=("a" * 40, "b" * 64),
                ),
                mock.patch.object(runner.secrets, "token_hex", return_value="d" * 64),
            ):
                with self.assertRaisesRegex(
                    runner.AcceptanceFailure, "public diagnostics written",
                ):
                    runner.main()
            command = process.call_args.args[0]
            self.assertIn(":app:connectedDebugAndroidTest", command)
            self.assertEqual(process.call_args.kwargs["timeout"], 1200)
            self.assertEqual(process.call_args.kwargs["runner_temp"], root)
            self.assertEqual(process.call_args.kwargs["diagnostic_nonce"], "d" * 64)
            self.assertIn(
                "-Pandroid.testInstrumentationRunnerArguments."
                f"rdpDiagnosticNonce={'d' * 64}",
                command,
            )
            self.assertFalse(report.exists())
            failure = root / "freerdp-public-acceptance/failure.json"
            payload = failure.read_text()
            self.assertIn("RdpPackagedHostAcceptanceTest.kt", payload)
            self.assertIn('"serverResizeRequested":true', payload)
            self.assertIn('"testLifecycleStage":"initialFrameWait"', payload)
            self.assertNotIn("d" * 64, payload)
            self.assertNotIn("disposable-password", payload)


if __name__ == "__main__":
    unittest.main()
