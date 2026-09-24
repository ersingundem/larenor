#!/usr/bin/env python3
"""Validate the K07 paired-remote software acceptance boundary."""

import argparse
import json
from pathlib import Path
import re
import stat
import sys


SOURCE_COMMIT = "d37ebb1ba4d778f5866016ebb8d5e9d827a5b7bb"
SHA = re.compile(r"[0-9a-f]{40}\Z")
RUN_URL = re.compile(
    r"https://github\.com/ersingundem/larenor/actions/runs/[1-9][0-9]*\Z"
)
REFERENCE = re.compile(
    r"(?:android|docs|lib|server|test|tool)/[A-Za-z0-9_./-]+\Z"
)
MAX_MANIFEST_BYTES = 64 * 1024
MAX_REFERENCE_BYTES = 2 * 1024 * 1024

REQUIRED_REFERENCES = {
    "production": frozenset(
        {
            "android/app/src/main/kotlin/com/ersingundem/larenor/kioskremote/"
            "ManagedTabletSourceBridge.kt",
            "lib/features/kiosk_remote/runtime/managed_tablet_credential_store.dart",
            "lib/features/kiosk_remote/runtime/managed_tablet_mqtt_runtime.dart",
            "lib/features/kiosk_remote/runtime/managed_tablet_profile_sync.dart",
            "lib/features/kiosk_remote/runtime/managed_tablet_runtime_owner.dart",
            "lib/features/kiosk_remote/runtime/managed_tablet_runtime_scope.dart",
            "lib/features/kiosk_remote/runtime/mqtt_local_broker.dart",
            "lib/features/kiosk_remote/runtime/native_managed_tablet_source.dart",
            "server/larenor_server/kiosk_remote/api.py",
        }
    ),
    "test": frozenset(
        {
            "android/app/src/test/kotlin/com/ersingundem/larenor/kioskremote/"
            "ManagedTabletSourceBridgeTest.kt",
            "server/tests/test_k07_paired_remote_mqtt.py",
            "server/tests/test_k07_tablet_profile_publication.py",
            "test/features/kiosk_remote/kiosk_remote_mqtt_runtime_test.dart",
            "test/features/kiosk_remote/managed_tablet_runtime_owner_test.dart",
            "test/features/kiosk_remote/mqtt_local_broker_live_test.dart",
            "test/features/kiosk_remote/native_managed_tablet_source_deadline_test.dart",
            "test/features/kiosk_remote/native_managed_tablet_source_test.dart",
        }
    ),
    "review": frozenset(
        {
            "docs/testing/k07-software-acceptance.tdd.md",
            "docs/testing/k07-versioned-profile-sync.tdd.md",
        }
    ),
}

REQUIRED_MARKERS = {
    "lib/features/kiosk_remote/runtime/managed_tablet_credential_store.dart": frozenset(
        {
            "final class CoreManagedTabletAuthority implements ManagedTabletCoreAuthority",
            "request.headers['X-Larenor-Pairing-Token'] = token",
            "throw const ManagedTabletRevoked()",
        }
    ),
    "lib/features/kiosk_remote/runtime/managed_tablet_runtime_owner.dart": frozenset(
        {
            "final class ManagedTabletRuntimeOwner",
            "await store.write(enrollment);",
            "await _schedule(startGeneration, enrollmentGuard: routeCurrent);",
            "// Do not rely on the authority result read before this callback.",
            "if (runtime != null) runtime.retire(),",
        }
    ),
    "lib/features/kiosk_remote/runtime/mqtt_local_broker.dart": frozenset(
        {
            "final class MqttClientLocalBroker implements LocalMqttBroker",
            "..secure = true",
            "..logging(on: false, logPayloads: false)",
            "mqtt_subscribe_rejected",
            "mqtt_publish_timeout",
        }
    ),
    "lib/features/kiosk_remote/runtime/managed_tablet_mqtt_runtime.dart": frozenset(
        {
            "if (kind == 'lockKiosk' && !current.scopes.contains('admin'))",
            "'mqtt_command_replay'",
            "'rate_limited'",
            "'refreshDashboard',",
            "'syncProfile',",
            "'lockKiosk',",
            "expiresAtMilliseconds > 8640000000000000",
        }
    ),
    "lib/features/kiosk_remote/runtime/native_managed_tablet_source.dart": frozenset(
        {
            "kind != 'refreshDashboard'",
            "kind != 'syncProfile'",
            "kind != 'lockKiosk'",
            "await _owner._retireLease(_lease);",
        }
    ),
    "lib/features/kiosk_remote/runtime/managed_tablet_profile_sync.dart": frozenset(
        {
            "final class ManagedTabletProfileSynchronizer",
            "await api.acknowledgeProfilePublication(",
            "!account.isCurrent(generation)",
        }
    ),
    "lib/features/kiosk_remote/runtime/managed_tablet_runtime_scope.dart": frozenset(
        {
            "final managedTabletLocalActionsProvider = Provider<ManagedTabletLocalActions>",
            "ref.invalidate(dashboardLayoutProvider);",
            ".synchronize(clientVersion: clientVersion, isCurrent: isCurrent)",
            "final managedTabletRuntimeOwnerProvider =",
        }
    ),
    (
        "android/app/src/main/kotlin/com/ersingundem/larenor/kioskremote/"
        "ManagedTabletSourceBridge.kt"
    ): frozenset(
        {
            'if (input["kind"] != "lockKiosk") invalid()',
            'return mapOf("result" to host.lockKiosk().name)',
            'exactMap(raw, setOf("sessionId", "kind"))',
        }
    ),
    "server/larenor_server/kiosk_remote/api.py": frozenset(
        {
            '@router.get(ROOT + "/pairings/{pairing_id}/mqtt/discovery")',
            'Header(alias="X-Larenor-Pairing-Token", min_length=43, max_length=43)',
        }
    ),
    "test/features/kiosk_remote/mqtt_local_broker_live_test.dart": frozenset(
        {
            "TLS adapter authenticates, subscribes and exchanges bounded MQTT packets",
            "TLS adapter fails closed when the broker rejects a subscription",
            "TLS adapter does not report publish success without broker receipt",
        }
    ),
    "test/features/kiosk_remote/kiosk_remote_mqtt_runtime_test.dart": frozenset(
        {
            "default-disabled runtime opens no broker and never exports its token",
            "telemetry, command ack, replay, rate limit and restart stay bounded",
            "out-of-range command numbers are rejected with exact acks",
        }
    ),
    "test/features/kiosk_remote/managed_tablet_runtime_owner_test.dart": frozenset(
        {
            "explicit enrollment starts only for the exact current binding",
            "current Core and egress are rechecked before broker connect",
            "Core revoke retires UI and native lease even when credential clear fails",
        }
    ),
    "test/features/kiosk_remote/native_managed_tablet_source_test.dart": frozenset(
        {
            "current lease executes only the bounded dashboard refresh",
            "retirement wins over a delayed profile synchronization",
            "native lock result is strict and cannot outlive its lease",
        }
    ),
    "test/features/kiosk_remote/native_managed_tablet_source_deadline_test.dart": frozenset(
        {
            "local action timeout retires lease before late work can commit",
            "native command timeout retires its platform session",
        }
    ),
}

ANDROID_REQUIRED_JOBS = frozenset(
    {
        "build-debug-apk",
        "analyze-test / static-analysis",
        "analyze-test / flutter-test (0)",
        "analyze-test / flutter-test (1)",
        "analyze-test / flutter-test (2)",
        "analyze-test / flutter-test (3)",
        "server-test / server-test-shard-0",
        "server-test / server-test-shard-1",
        "server-test / server-test-shard-2",
        "server-test / server-test-shard-3",
        "server-test / server-test",
        "end-to-end / emulator-journeys",
    }
)
SECURITY_REQUIRED_JOBS = frozenset(
    {"dependency-scan", "platform-policy", "secret-scan"}
)
MANUAL_BOUNDARY = (
    "Physical Huawei, DeX, TalkBack, OEM, DPC, broker deployment and device "
    "measurements remain separate manual gates."
)


class AcceptanceError(ValueError):
    """Static failure codes safe for local and CI output."""


def _require(condition, code):
    if not condition:
        raise AcceptanceError(code)


def _exact_fields(value, fields):
    _require(type(value) is dict and set(value) == set(fields), "invalid_schema")


def validate_reference_content(path, content):
    _require(isinstance(content, str), "invalid_reference")
    for marker in REQUIRED_MARKERS.get(path, ()):
        _require(marker in content, "missing_guard")


def _reference(path, root):
    _require(
        isinstance(path, str)
        and REFERENCE.fullmatch(path)
        and ".." not in path.split("/")
        and "//" not in path
        and not path.endswith("/"),
        "invalid_reference",
    )
    target = root / path
    try:
        value = target.lstat()
    except OSError as error:
        raise AcceptanceError("missing_reference") from error
    _require(stat.S_ISREG(value.st_mode) and not target.is_symlink(), "invalid_reference")
    _require(0 < value.st_size <= MAX_REFERENCE_BYTES, "invalid_reference")
    try:
        content = target.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as error:
        raise AcceptanceError("invalid_reference") from error
    validate_reference_content(path, content)


def _ci(value, jobs):
    _exact_fields(value, ("url", "commit", "result", "requiredJobs"))
    _require(isinstance(value["url"], str) and RUN_URL.fullmatch(value["url"]), "invalid_ci")
    _require(isinstance(value["commit"], str) and SHA.fullmatch(value["commit"]), "stale_ci")
    _require(value["result"] == "passed", "invalid_ci")
    required_jobs = value["requiredJobs"]
    _require(
        type(required_jobs) is list
        and len(required_jobs) == len(set(required_jobs))
        and frozenset(required_jobs) == jobs,
        "missing_ci_job",
    )


def validate_manifest(value, root, *, allow_pending=False):
    root = Path(root).resolve()
    _exact_fields(
        value,
        (
            "schemaVersion",
            "task",
            "status",
            "sourceCommit",
            "review",
            "references",
            "ci",
            "manualBoundary",
        ),
    )
    _require(value["schemaVersion"] == 1, "invalid_schema")
    _require(value["task"] == "K07", "invalid_task")
    _require(value["status"] in {"pending", "accepted"}, "invalid_status")
    _require(value["sourceCommit"] == SOURCE_COMMIT, "stale_source")
    references = value["references"]
    _exact_fields(references, REQUIRED_REFERENCES)
    for group, required in REQUIRED_REFERENCES.items():
        actual = references[group]
        _require(
            type(actual) is list
            and all(isinstance(path, str) for path in actual),
            "invalid_reference",
        )
        for path in actual:
            _reference(path, root)
        _require(
            len(actual) == len(set(actual)) and frozenset(actual) == required,
            "missing_reference",
        )
    _require(value["manualBoundary"] == MANUAL_BOUNDARY, "invalid_manual_boundary")
    if value["status"] == "pending":
        _require(value["review"] is None and value["ci"] is None, "invalid_pending")
        _require(allow_pending, "acceptance_pending")
        return value
    review = value["review"]
    _exact_fields(review, ("commit", "result", "ref"))
    _require(
        isinstance(review["commit"], str) and SHA.fullmatch(review["commit"]),
        "invalid_review",
    )
    _require(review["result"] == "passed", "invalid_review")
    _require(review["ref"] == "docs/testing/k07-software-acceptance.tdd.md", "invalid_review")
    ci = value["ci"]
    _exact_fields(ci, ("android", "security"))
    _ci(ci["android"], ANDROID_REQUIRED_JOBS)
    _ci(ci["security"], SECURITY_REQUIRED_JOBS)
    _require(
        ci["android"]["commit"] == ci["security"]["commit"] == review["commit"],
        "stale_ci",
    )
    return value


def load_manifest(path, root=None, *, allow_pending=False):
    path = Path(path)
    root = path.resolve().parents[2] if root is None else Path(root)
    try:
        file_stat = path.lstat()
        _require(
            stat.S_ISREG(file_stat.st_mode)
            and not path.is_symlink()
            and 0 < file_stat.st_size <= MAX_MANIFEST_BYTES,
            "invalid_manifest",
        )
        value = json.loads(path.read_text(encoding="utf-8"))
    except AcceptanceError:
        raise
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise AcceptanceError("invalid_manifest") from error
    return validate_manifest(value, root, allow_pending=allow_pending)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--manifest",
        type=Path,
        default=Path(__file__).resolve().parents[1]
        / "docs/testing/k07-software-acceptance.json",
    )
    parser.add_argument("--allow-pending", action="store_true")
    args = parser.parse_args(argv)
    try:
        value = load_manifest(args.manifest, allow_pending=args.allow_pending)
    except AcceptanceError as error:
        sys.stderr.write("K07 acceptance error: %s\n" % error)
        return 2
    sys.stdout.write("K07 acceptance %s %s\n" % (value["status"].upper(), value["sourceCommit"]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
