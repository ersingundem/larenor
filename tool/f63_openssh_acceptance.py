#!/usr/bin/env python3
"""Run and receipt the exact real-OpenSSH Flutter acceptance tests."""

from __future__ import annotations

import json
import os
from pathlib import Path
import re
import subprocess
import sys

if __package__:
    from .native_acceptance_receipt import (
        NativeAcceptanceReceiptError,
        source_revision,
    )
else:
    from native_acceptance_receipt import (
        NativeAcceptanceReceiptError,
        source_revision,
    )


ROOT = Path(__file__).resolve().parents[1]
TEST_FILE = "test/features/remote_access/ssh/ssh_native_fixture_test.dart"
OUTPUT = ROOT / "build" / "f63-openssh-acceptance"
REPORT = OUTPUT / "native-events.json"
RECEIPT = OUTPUT / "receipt.json"
MAX_REPORT_BYTES = 2 * 1024 * 1024
MAX_EVENTS = 4096
EXPECTED_TESTS = (
    "password authentication opens the real protocol shell",
    "keyboard-interactive MFA completes prompted and zero-prompt PAM rounds",
    "independent pinned jump and target open a real forwarded shell",
    "encrypted key, pinned host and PTY preserve UTF-8 and terminal size",
    "SFTP list and transfers are bounded and cancellation closes ownership",
    "wrong host pin and closed local tunnel fail without retry or replay",
    "authority loss after local bind closes the unpublished listener",
)
REQUIRED_ENVIRONMENT = (
    "OPENSSH_PACKAGE",
    "LARENOR_SSH_FIXTURE_PORT",
    "LARENOR_SSH_JUMP_PORT",
    "LARENOR_SSH_MFA_PORT",
    "LARENOR_SSH_TUNNEL_PORT",
    "LARENOR_SSH_TARGET_PORT",
    "LARENOR_SSH_FIXTURE_USER",
    "LARENOR_SSH_PRIVATE_KEY",
    "LARENOR_SSH_KEY_PASSPHRASE",
    "LARENOR_SSH_HOST_KEY_TYPE",
    "LARENOR_SSH_HOST_KEY_FINGERPRINT",
    "LARENOR_SSH_JUMP_HOST_KEY_TYPE",
    "LARENOR_SSH_JUMP_HOST_KEY_FINGERPRINT",
    "LARENOR_SSH_MFA_HOST_KEY_TYPE",
    "LARENOR_SSH_MFA_HOST_KEY_FINGERPRINT",
    "LARENOR_SSH_FIXTURE_PASSWORD",
    "LARENOR_SFTP_FIXTURE_ROOT",
)
PORT_ENVIRONMENT = (
    "LARENOR_SSH_FIXTURE_PORT",
    "LARENOR_SSH_JUMP_PORT",
    "LARENOR_SSH_MFA_PORT",
    "LARENOR_SSH_TUNNEL_PORT",
    "LARENOR_SSH_TARGET_PORT",
)
HOST_KEYS = (
    (
        "direct",
        "LARENOR_SSH_HOST_KEY_TYPE",
        "LARENOR_SSH_HOST_KEY_FINGERPRINT",
    ),
    (
        "jump",
        "LARENOR_SSH_JUMP_HOST_KEY_TYPE",
        "LARENOR_SSH_JUMP_HOST_KEY_FINGERPRINT",
    ),
    (
        "mfa",
        "LARENOR_SSH_MFA_HOST_KEY_TYPE",
        "LARENOR_SSH_MFA_HOST_KEY_FINGERPRINT",
    ),
)
_PACKAGE_VERSION = re.compile(r"[0-9A-Za-z][0-9A-Za-z.+:~_-]{0,127}")
_SHA256_FINGERPRINT = re.compile(r"SHA256:[A-Za-z0-9+/]{43}")


class AcceptanceFailure(RuntimeError):
    pass


def _pairs(values):
    result = {}
    for key, value in values:
        if key in result:
            raise AcceptanceFailure("duplicate JSON event key")
        result[key] = value
    return result


def validate_environment(environment: dict[str, str]) -> None:
    missing = [name for name in REQUIRED_ENVIRONMENT if not environment.get(name)]
    if missing:
        raise AcceptanceFailure(
            "missing fixture environment: " + ", ".join(sorted(missing))
        )
    ports = []
    for name in PORT_ENVIRONMENT:
        try:
            value = int(environment[name])
        except (TypeError, ValueError) as error:
            raise AcceptanceFailure(f"invalid fixture port: {name}") from error
        if not 1 <= value <= 65535:
            raise AcceptanceFailure(f"invalid fixture port: {name}")
        ports.append(value)
    if len(set(ports)) != len(ports):
        raise AcceptanceFailure("fixture ports must be distinct")
    package = environment["OPENSSH_PACKAGE"]
    if _PACKAGE_VERSION.fullmatch(package) is None:
        raise AcceptanceFailure("OpenSSH package version is invalid")
    for _, algorithm_name, fingerprint_name in HOST_KEYS:
        if environment[algorithm_name] != "ssh-ed25519":
            raise AcceptanceFailure(f"fixture host key algorithm is invalid: {algorithm_name}")
        if _SHA256_FINGERPRINT.fullmatch(environment[fingerprint_name]) is None:
            raise AcceptanceFailure(
                f"fixture host key fingerprint is invalid: {fingerprint_name}"
            )


def provider_identity(environment, *, command_runner=subprocess.run):
    validate_environment(environment)
    command = [
        "dpkg-query",
        "--show",
        "--showformat=${Version}",
        "openssh-server",
    ]
    try:
        result = command_runner(
            command,
            check=False,
            capture_output=True,
            text=True,
            timeout=10,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        raise AcceptanceFailure("OpenSSH provider identity is unavailable") from error
    lines = result.stdout.splitlines()
    if (
        result.returncode != 0
        or len(lines) != 1
        or lines[0] != environment["OPENSSH_PACKAGE"]
    ):
        raise AcceptanceFailure("OpenSSH provider identity does not match fixture")
    return {
        "implementation": "OpenSSH",
        "packageVersion": lines[0],
        "hostKeys": [
            {
                "role": role,
                "algorithm": environment[algorithm_name],
                "fingerprintSha256": environment[fingerprint_name],
            }
            for role, algorithm_name, fingerprint_name in HOST_KEYS
        ],
    }


def _events(path: Path):
    try:
        size = path.stat().st_size
        if size <= 0 or size > MAX_REPORT_BYTES:
            raise AcceptanceFailure("OpenSSH acceptance report size is invalid")
        with path.open(encoding="utf-8") as source:
            for index, line in enumerate(source, start=1):
                if index > MAX_EVENTS:
                    raise AcceptanceFailure("OpenSSH acceptance report has too many events")
                try:
                    event = json.loads(line, object_pairs_hook=_pairs)
                except (json.JSONDecodeError, UnicodeError) as error:
                    raise AcceptanceFailure(
                        "OpenSSH acceptance report contains invalid JSON"
                    ) from error
                if not isinstance(event, dict):
                    raise AcceptanceFailure("OpenSSH acceptance event is not an object")
                yield event
    except OSError as error:
        raise AcceptanceFailure("OpenSSH acceptance report is unavailable") from error


def _is_loading_test(name: str) -> bool:
    prefix = "loading "
    return name.startswith(prefix) and name[len(prefix) :].replace("\\", "/").endswith(
        TEST_FILE
    )


def verify_report(path: Path = REPORT) -> dict[str, object]:
    suite_ids: set[int] = set()
    suite_starts: dict[int, str] = {}
    suite_completions: set[int] = set()
    starts: dict[int, str] = {}
    completions: dict[str, int] = {}
    loading_ids: set[int] = set()
    done_events = 0
    matching_suite_seen = False
    finished = False
    for event in _events(path):
        if finished:
            raise AcceptanceFailure(
                "OpenSSH acceptance report contains events after completion"
            )
        kind = event.get("type")
        if kind == "suite":
            suite = event.get("suite")
            if not isinstance(suite, dict):
                raise AcceptanceFailure("OpenSSH acceptance suite is malformed")
            suite_path = suite.get("path")
            suite_id = suite.get("id")
            if isinstance(suite_path, str) and suite_path.replace("\\", "/").endswith(
                TEST_FILE
            ):
                if not isinstance(suite_id, int) or isinstance(suite_id, bool):
                    raise AcceptanceFailure("OpenSSH acceptance suite is malformed")
                if matching_suite_seen:
                    raise AcceptanceFailure(
                        "OpenSSH acceptance suite was reported more than once"
                    )
                matching_suite_seen = True
                suite_ids.add(suite_id)
        elif kind == "testStart":
            test = event.get("test")
            if not isinstance(test, dict):
                raise AcceptanceFailure("OpenSSH acceptance test start is malformed")
            suite_id = test.get("suiteID")
            if isinstance(suite_id, bool):
                raise AcceptanceFailure("OpenSSH acceptance test start is malformed")
            if suite_id not in suite_ids:
                continue
            test_id = test.get("id")
            name = test.get("name")
            metadata = test.get("metadata")
            if (
                not isinstance(test_id, int)
                or isinstance(test_id, bool)
                or not isinstance(name, str)
            ):
                raise AcceptanceFailure("OpenSSH acceptance test start is malformed")
            if test_id in suite_starts:
                raise AcceptanceFailure("OpenSSH acceptance test started more than once")
            suite_starts[test_id] = name
            if name in EXPECTED_TESTS:
                if name in starts.values():
                    raise AcceptanceFailure("OpenSSH acceptance test started more than once")
                if not isinstance(metadata, dict) or metadata.get("skip") is not False:
                    raise AcceptanceFailure("OpenSSH acceptance test was declared skipped")
                starts[test_id] = name
            elif _is_loading_test(name):
                if loading_ids:
                    raise AcceptanceFailure(
                        "OpenSSH acceptance loading test started more than once"
                    )
                loading_ids.add(test_id)
            else:
                raise AcceptanceFailure("unexpected OpenSSH acceptance test started")
        elif kind == "testDone":
            test_id = event.get("testID")
            if isinstance(test_id, bool):
                raise AcceptanceFailure("OpenSSH acceptance test completion is malformed")
            if test_id not in suite_starts:
                continue
            name = suite_starts[test_id]
            if event.get("hidden") is True:
                if (
                    test_id not in loading_ids
                    or event.get("skipped") is not False
                    or event.get("result") != "success"
                ):
                    raise AcceptanceFailure("unexpected hidden OpenSSH test completed")
                if test_id in suite_completions:
                    raise AcceptanceFailure(
                        "OpenSSH acceptance test completed more than once"
                    )
                suite_completions.add(test_id)
                continue
            if name not in EXPECTED_TESTS:
                raise AcceptanceFailure("unexpected OpenSSH acceptance test completed")
            if name in completions:
                raise AcceptanceFailure("OpenSSH acceptance test completed more than once")
            if (
                event.get("hidden") is not False
                or event.get("skipped") is not False
                or event.get("result") != "success"
            ):
                raise AcceptanceFailure("OpenSSH acceptance test did not pass")
            completions[name] = 1
            suite_completions.add(test_id)
        elif kind == "error":
            raise AcceptanceFailure("OpenSSH acceptance report contains an error")
        elif kind == "done":
            done_events += 1
            if event.get("success") is not True:
                raise AcceptanceFailure("OpenSSH acceptance runner did not succeed")
            finished = True
    if len(suite_ids) != 1:
        raise AcceptanceFailure("exact OpenSSH acceptance suite is unavailable")
    if len(loading_ids) != 1:
        raise AcceptanceFailure("exact OpenSSH acceptance loading test is unavailable")
    if set(starts.values()) != set(EXPECTED_TESTS):
        raise AcceptanceFailure("exact OpenSSH acceptance tests did not start")
    if set(completions) != set(EXPECTED_TESTS):
        raise AcceptanceFailure("exact OpenSSH acceptance tests did not complete")
    if suite_completions != set(suite_starts):
        raise AcceptanceFailure("OpenSSH acceptance test completion is missing")
    if done_events != 1:
        raise AcceptanceFailure("OpenSSH acceptance runner completion is ambiguous")
    return {
        "schemaVersion": 1,
        "testFile": TEST_FILE,
        "result": "passed",
        "tests": len(EXPECTED_TESTS),
        "skipped": 0,
        "failures": 0,
        "errors": 0,
        "testNames": list(EXPECTED_TESTS),
    }


def build_receipt(
    path: Path,
    environment: dict[str, str],
    *,
    root: Path = ROOT,
    command_runner=subprocess.run,
) -> dict[str, object]:
    receipt = verify_report(path)
    try:
        revision = source_revision(root)
    except NativeAcceptanceReceiptError as error:
        raise AcceptanceFailure(
            "OpenSSH acceptance source revision is unavailable"
        ) from error
    receipt["sourceRevision"] = revision
    receipt["provider"] = provider_identity(
        environment,
        command_runner=command_runner,
    )
    return receipt


def main() -> int:
    environment = dict(os.environ)
    validate_environment(environment)
    OUTPUT.mkdir(parents=True, exist_ok=True)
    REPORT.unlink(missing_ok=True)
    RECEIPT.unlink(missing_ok=True)
    try:
        result = subprocess.run(
            [
                "flutter",
                "test",
                "--no-pub",
                "--reporter",
                "expanded",
                "--file-reporter",
                f"json:{REPORT}",
                TEST_FILE,
            ],
            cwd=ROOT,
            check=False,
            timeout=300,
        )
    except (OSError, subprocess.TimeoutExpired):
        raise AcceptanceFailure("OpenSSH acceptance runner did not complete") from None
    if result.returncode:
        raise AcceptanceFailure("OpenSSH acceptance runner failed")
    receipt = build_receipt(REPORT, environment)
    RECEIPT.write_text(
        json.dumps(receipt, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except AcceptanceFailure as failure:
        print(f"F63 OpenSSH acceptance unavailable: {failure}", file=sys.stderr)
        raise SystemExit(2)
