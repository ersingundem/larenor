import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

from tool import f63_openssh_acceptance as runner


def event(kind, **values):
    return {"type": kind, **values}


class F63OpenSshAcceptanceTest(unittest.TestCase):
    def test_hosted_script_entry_point_has_no_pythonpath_dependency(self):
        environment = {
            key: value for key, value in os.environ.items()
            if key not in runner.REQUIRED_ENVIRONMENT and key != "PYTHONPATH"
        }
        result = subprocess.run(
            [sys.executable, "-E", str(runner.ROOT / "tool/f63_openssh_acceptance.py")],
            cwd=runner.ROOT,
            env=environment,
            capture_output=True,
            text=True,
            timeout=10,
            check=False,
        )
        self.assertEqual(result.returncode, 2)
        self.assertIn("missing fixture environment:", result.stderr)
        self.assertNotIn("Traceback", result.stderr)
        self.assertEqual(result.stdout, "")

    def _environment(self):
        environment = {name: "fixture" for name in runner.REQUIRED_ENVIRONMENT}
        for index, name in enumerate(runner.PORT_ENVIRONMENT, start=22000):
            environment[name] = str(index)
        environment.update(
            {
                "OPENSSH_PACKAGE": "1:9.6p1-3ubuntu13.19",
                "LARENOR_SSH_HOST_KEY_TYPE": "ssh-ed25519",
                "LARENOR_SSH_JUMP_HOST_KEY_TYPE": "ssh-ed25519",
                "LARENOR_SSH_MFA_HOST_KEY_TYPE": "ssh-ed25519",
                "LARENOR_SSH_HOST_KEY_FINGERPRINT": "SHA256:" + "A" * 43,
                "LARENOR_SSH_JUMP_HOST_KEY_FINGERPRINT": "SHA256:" + "B" * 43,
                "LARENOR_SSH_MFA_HOST_KEY_FINGERPRINT": "SHA256:" + "C" * 43,
                "LARENOR_SSH_FIXTURE_PASSWORD": "private-password-value",
                "LARENOR_SSH_KEY_PASSPHRASE": "private-passphrase-value",
            }
        )
        return environment

    def _report(self, directory: Path, *, changed=None):
        suite = 17
        events = [
            event("suite", suite={"id": suite, "path": f"/checkout/{runner.TEST_FILE}"})
        ]
        events.extend(
            [
                event(
                    "testStart",
                    test={
                        "id": 700,
                        "suiteID": suite,
                        "name": f"loading /checkout/{runner.TEST_FILE}",
                        "metadata": {"skip": False, "skipReason": None},
                    },
                ),
                event(
                    "testDone",
                    testID=700,
                    hidden=True,
                    skipped=False,
                    result="success",
                ),
            ]
        )
        for index, name in enumerate(runner.EXPECTED_TESTS, start=1):
            events.extend(
                [
                    event(
                        "testStart",
                        test={
                            "id": index,
                            "suiteID": suite,
                            "name": name,
                            "metadata": {"skip": False, "skipReason": None},
                        },
                    ),
                    event(
                        "testDone",
                        testID=index,
                        hidden=False,
                        skipped=False,
                        result="success",
                    ),
                ]
            )
        events.append(event("done", success=True))
        if changed is not None:
            changed(events)
        path = directory / "events.json"
        path.write_text(
            "".join(json.dumps(item) + "\n" for item in events),
            encoding="utf-8",
        )
        return path

    def test_exact_seven_named_non_skipped_completions_receipt(self):
        with tempfile.TemporaryDirectory() as temporary:
            receipt = runner.verify_report(self._report(Path(temporary)))
        self.assertEqual(receipt["tests"], 7)
        self.assertEqual(receipt["skipped"], 0)
        self.assertEqual(receipt["testNames"], list(runner.EXPECTED_TESTS))

    def test_actual_flutter_loading_event_flow_is_accepted(self):
        def add_machine_protocol_events(events):
            events.insert(
                0,
                event(
                    "start",
                    protocolVersion="0.1.1",
                    runnerVersion="test",
                    pid=1,
                ),
            )
            events.insert(3, event("allSuites", count=1))
            events.insert(5, event("group", group={"id": 1, "suiteID": 17}))
            events.insert(-1, event("print", testID=1, line="fixture output"))

        with tempfile.TemporaryDirectory() as temporary:
            receipt = runner.verify_report(
                self._report(Path(temporary), changed=add_machine_protocol_events)
            )
        self.assertEqual(receipt["result"], "passed")

    def test_skip_failure_missing_and_duplicate_completion_are_rejected(self):
        changes = (
            lambda events: events.__setitem__(4, {**events[4], "skipped": True}),
            lambda events: events.pop(4),
            lambda events: events.insert(5, dict(events[4])),
            lambda events: events[-1].update(success=False),
            lambda events: events.__setitem__(
                slice(-1, -1),
                [
                    event(
                        "testStart",
                        test={
                            "id": 99,
                            "suiteID": 17,
                            "name": "unexpected acceptance",
                            "metadata": {"skip": False},
                        },
                    ),
                    event(
                        "testDone",
                        testID=99,
                        hidden=False,
                        skipped=False,
                        result="success",
                    ),
                ],
            ),
        )
        for change in changes:
            with self.subTest(change=change):
                with tempfile.TemporaryDirectory() as temporary:
                    path = self._report(Path(temporary), changed=change)
                    with self.assertRaises(runner.AcceptanceFailure):
                        runner.verify_report(path)

    def test_duplicate_matching_suite_even_with_same_id_is_rejected(self):
        def duplicate(events):
            events.insert(1, dict(events[0]))

        with tempfile.TemporaryDirectory() as temporary:
            path = self._report(Path(temporary), changed=duplicate)
            with self.assertRaises(runner.AcceptanceFailure):
                runner.verify_report(path)

    def test_second_loading_flow_is_rejected(self):
        def duplicate_loading(events):
            events[-1:-1] = [
                event(
                    "testStart",
                    test={
                        "id": 701,
                        "suiteID": 17,
                        "name": f"loading /checkout/{runner.TEST_FILE}",
                        "metadata": {"skip": False},
                    },
                ),
                event(
                    "testDone",
                    testID=701,
                    hidden=True,
                    skipped=False,
                    result="success",
                ),
            ]

        with tempfile.TemporaryDirectory() as temporary:
            path = self._report(Path(temporary), changed=duplicate_loading)
            with self.assertRaises(runner.AcceptanceFailure):
                runner.verify_report(path)

    def test_boolean_suite_test_and_completion_ids_are_rejected(self):
        changes = (
            lambda events: events[0]["suite"].update(id=True),
            lambda events: events[3]["test"].update(suiteID=True),
            lambda events: events[3]["test"].update(id=True),
            lambda events: events[4].update(testID=True),
        )
        for change in changes:
            with self.subTest(change=change):
                with tempfile.TemporaryDirectory() as temporary:
                    path = self._report(Path(temporary), changed=change)
                    with self.assertRaises(runner.AcceptanceFailure):
                        runner.verify_report(path)

    def test_unexpected_nonloading_start_without_completion_is_rejected(self):
        def add_unexpected(events):
            events.insert(
                -1,
                event(
                    "testStart",
                    test={
                        "id": 999,
                        "suiteID": 17,
                        "name": "unexpected acceptance",
                        "metadata": {"skip": False},
                    },
                ),
            )

        with tempfile.TemporaryDirectory() as temporary:
            path = self._report(Path(temporary), changed=add_unexpected)
            with self.assertRaises(runner.AcceptanceFailure):
                runner.verify_report(path)

    def test_semantic_event_after_done_is_rejected(self):
        def add_after_done(events):
            events.append(
                event(
                    "testDone",
                    testID=999,
                    hidden=False,
                    skipped=False,
                    result="success",
                )
            )

        with tempfile.TemporaryDirectory() as temporary:
            path = self._report(Path(temporary), changed=add_after_done)
            with self.assertRaises(runner.AcceptanceFailure):
                runner.verify_report(path)

    def test_malformed_and_duplicate_json_keys_are_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "events.json"
            for contents in ("not-json\n", '{"type":"done","type":"done"}\n'):
                path.write_text(contents, encoding="utf-8")
                with self.assertRaises(runner.AcceptanceFailure):
                    runner.verify_report(path)

    def test_environment_requires_every_value_and_distinct_bounded_ports(self):
        environment = self._environment()
        runner.validate_environment(environment)

        for changed in (
            {**environment, "LARENOR_SSH_PRIVATE_KEY": ""},
            {**environment, "LARENOR_SSH_FIXTURE_PORT": "0"},
            {
                **environment,
                "LARENOR_SSH_FIXTURE_PORT": environment["LARENOR_SSH_JUMP_PORT"],
            },
        ):
            with self.assertRaises(runner.AcceptanceFailure):
                runner.validate_environment(changed)

    def test_receipt_binds_source_and_observed_openssh_identity(self):
        environment = self._environment()
        calls = []

        def query(command, **options):
            calls.append((command, options))
            return subprocess.CompletedProcess(
                command,
                0,
                stdout=environment["OPENSSH_PACKAGE"] + "\n",
                stderr="",
            )

        with tempfile.TemporaryDirectory() as temporary:
            path = self._report(Path(temporary))
            with mock.patch.object(
                runner, "source_revision", return_value="a" * 40
            ):
                receipt = runner.build_receipt(
                    path,
                    environment,
                    root=Path(temporary),
                    command_runner=query,
                )

        self.assertEqual(receipt["sourceRevision"], "a" * 40)
        self.assertEqual(
            receipt["provider"],
            {
                "implementation": "OpenSSH",
                "packageVersion": "1:9.6p1-3ubuntu13.19",
                "hostKeys": [
                    {
                        "role": "direct",
                        "algorithm": "ssh-ed25519",
                        "fingerprintSha256": "SHA256:" + "A" * 43,
                    },
                    {
                        "role": "jump",
                        "algorithm": "ssh-ed25519",
                        "fingerprintSha256": "SHA256:" + "B" * 43,
                    },
                    {
                        "role": "mfa",
                        "algorithm": "ssh-ed25519",
                        "fingerprintSha256": "SHA256:" + "C" * 43,
                    },
                ],
            },
        )
        self.assertEqual(
            calls[0][0],
            [
                "dpkg-query",
                "--show",
                "--showformat=${Version}",
                "openssh-server",
            ],
        )
        serialized = json.dumps(receipt)
        self.assertNotIn(environment["LARENOR_SSH_FIXTURE_PASSWORD"], serialized)
        self.assertNotIn(environment["LARENOR_SSH_KEY_PASSPHRASE"], serialized)

    def test_provider_identity_rejects_malformed_or_unobserved_metadata(self):
        environment = self._environment()
        failures = (
            (
                {**environment, "LARENOR_SSH_HOST_KEY_FINGERPRINT": "not-a-fingerprint"},
                environment["OPENSSH_PACKAGE"],
            ),
            (environment, "1:9.6p1-unexpected"),
        )
        for changed, observed in failures:
            with self.subTest(observed=observed):
                with self.assertRaises(runner.AcceptanceFailure):
                    runner.provider_identity(
                        changed,
                        command_runner=lambda command, **options: subprocess.CompletedProcess(
                            command, 0, stdout=observed + "\n", stderr=""
                        ),
                    )


if __name__ == "__main__":
    unittest.main()
