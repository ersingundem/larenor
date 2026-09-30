import json
from pathlib import Path
import tempfile
import unittest

from tool import f63_openssh_acceptance as runner


def event(kind, **values):
    return {"type": kind, **values}


class F63OpenSshAcceptanceTest(unittest.TestCase):
    def _report(self, directory: Path, *, changed=None):
        suite = 17
        events = [
            event("suite", suite={"id": suite, "path": f"/checkout/{runner.TEST_FILE}"})
        ]
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

    def test_skip_failure_missing_and_duplicate_completion_are_rejected(self):
        changes = (
            lambda events: events.__setitem__(2, {**events[2], "skipped": True}),
            lambda events: events.pop(2),
            lambda events: events.insert(3, dict(events[2])),
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

    def test_malformed_and_duplicate_json_keys_are_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "events.json"
            for contents in ("not-json\n", '{"type":"done","type":"done"}\n'):
                path.write_text(contents, encoding="utf-8")
                with self.assertRaises(runner.AcceptanceFailure):
                    runner.verify_report(path)

    def test_environment_requires_every_value_and_distinct_bounded_ports(self):
        environment = {name: "fixture" for name in runner.REQUIRED_ENVIRONMENT}
        for index, name in enumerate(runner.PORT_ENVIRONMENT, start=22000):
            environment[name] = str(index)
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


if __name__ == "__main__":
    unittest.main()
