#!/usr/bin/env python3
"""Manual CI adapter for native image and network resource acceptance."""

import json
import os
from pathlib import Path
import re
import signal
import sys

from tool import jellyfin_storage_smoke as owned
from tool import media_resource_smoke as smoke


class ResourceCIError(Exception):
    pass


class _Cancelled(BaseException):
    pass


def _require(value):
    if not value:
        raise ResourceCIError("resource_characterization_evidence_invalid")


def source_hashes():
    return smoke.source_hashes()


def _same(left, right):
    if type(left) is not type(right):
        return False
    if type(right) is dict:
        return left.keys() == right.keys() and all(_same(left[key], value)
                                                  for key, value in right.items())
    if type(right) is list:
        return len(left) == len(right) and all(_same(a, b) for a, b in zip(left, right))
    return left == right


def validate_launch(environment, system, machine, uid):
    try:
        selected = owned.native_platform(environment, system, machine, uid)
    except Exception:
        raise ResourceCIError("resource_characterization_evidence_invalid") from None
    _require(environment.get("GITHUB_EVENT_NAME") == "workflow_dispatch"
             and environment.get("GITHUB_REF") == "refs/heads/main"
             and environment.get("GITHUB_REPOSITORY") == "ersingundem/larenor"
             and environment.get("GITHUB_WORKFLOW_SHA") == environment.get("GITHUB_SHA")
             and environment.get("EXPECTED_PLATFORM") == selected)
    return selected


def validate_receipt(value, commit, selected):
    _require(type(commit) is str and re.fullmatch(r"[0-9a-f]{40}", commit) is not None
             and selected in ("linux/amd64", "linux/arm64"))
    source = owned.fixture_source(selected)
    hashes = source_hashes()
    targets = smoke.select_resources(source)
    expected = {
        "schemaVersion": 1,
        "result": "resources_ready",
        "platform": selected,
        "sourceCommit": commit,
        "catalogDigest": source.catalog.digest,
        "imageConfigDigest": targets.image.image.configDigest,
        "imageState": "ready",
        "networkState": "ready",
        "networkIdentitySha256": value.get("networkIdentitySha256") if type(value) is dict else None,
        "journalRestartCount": 1,
        "resourceKinds": ["ensure_image", "prepare_control_network"],
        "resourceCount": 2,
        "containerOperations": 0,
        "installAvailable": False,
        "sourceHashes": hashes,
    }
    identity = expected["networkIdentitySha256"]
    _require(type(identity) is str and re.fullmatch(r"[0-9a-f]{64}", identity) is not None
             and _same(value, expected))


def run():
    selected = validate_launch(os.environ, owned.platform.system(),
                               owned.platform.machine(), os.geteuid())
    commit = os.environ["GITHUB_SHA"]
    owner = owned.EphemeralDaemon()
    signals = (signal.SIGINT, signal.SIGTERM, signal.SIGALRM)
    previous = {item: signal.getsignal(item) for item in signals}

    def cancel(_signum, _frame):
        for item in signals:
            signal.signal(item, signal.SIG_IGN)
        owner.emergency_cleanup()
        raise _Cancelled()

    try:
        for item in signals:
            signal.signal(item, cancel)
        signal.alarm(1200)
        binding = smoke.capture_source(commit)
        with owner as daemon:
            value = smoke.characterize(daemon, checkout_binding=binding)
        smoke.check_source(binding)
        validate_receipt(value, commit, selected)
        print(json.dumps(value, sort_keys=True, separators=(",", ":")))
    finally:
        signal.alarm(0)
        for item, handler in previous.items():
            signal.signal(item, handler)


def _unique(pairs):
    value = {}
    for key, item in pairs:
        _require(key not in value)
        value[key] = item
    return value


def _nonfinite(_value):
    raise ResourceCIError("resource_characterization_evidence_invalid")


def verify(path):
    try:
        with Path(path).open("rb") as source:
            raw = source.read(32769)
        _require(0 < len(raw) <= 32768)
        value = json.loads(raw, object_pairs_hook=_unique, parse_constant=_nonfinite)
        commit = os.environ.get("GITHUB_SHA", "")
        selected = os.environ.get("EXPECTED_PLATFORM", "")
        smoke.verify_checkout(commit)
        validate_receipt(value, commit, selected)
        print("resource_characterization_receipt_verified")
    except ResourceCIError:
        raise
    except Exception:
        raise ResourceCIError("resource_characterization_evidence_invalid") from None


def main(arguments=None):
    arguments = sys.argv[1:] if arguments is None else arguments
    try:
        if arguments == ["--run-ephemeral-ci"]:
            run()
        elif len(arguments) == 2 and arguments[0] == "--verify-receipt":
            verify(arguments[1])
        else:
            raise ResourceCIError("resource_characterization_evidence_invalid")
        return 0
    except _Cancelled:
        print("resource_characterization_cancelled", file=sys.stderr)
    except Exception:
        print("resource_characterization_evidence_invalid", file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
