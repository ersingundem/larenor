#!/usr/bin/env python3
"""Focused owned Sunshine startup probe for the F60 stream profile."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import stat
import sys
from typing import Mapping, Optional, Sequence

from tool.f60_sunshine_owned_host import (
    HostFailure,
    HostStartupFailure,
    OwnedSunshineHost,
    SUNSHINE_SHA256,
    SUNSHINE_TAG,
)
from tool.native_acceptance_receipt import source_revision


ROOT = Path(__file__).resolve().parents[1]
RECEIPT_NAME = "f60-sunshine-startup-probe.json"
MAX_RECEIPT_BYTES = 8192
_STARTUP_STAGES = frozenset({
    "packageAcquisition", "packageInstallation", "materialSetup", "tlsIdentity",
    "credentialSetup", "audioLaunch", "audioReadiness", "displayLaunch",
    "displayReadiness", "sunshineLaunch", "apiReadiness", "mdnsReadiness",
    "finalReadiness",
})
_STARTUP_PROCESSES = frozenset({"none", "audio", "display", "sunshine", "multiple"})
_STARTUP_POLLS = frozenset({"notStarted", "running", "exited"})
_STARTUP_EXITS = frozenset({"unavailable", "zero", "nonzero", "signal"})
_STARTUP_CODES = frozenset({
    "unclassified", "encoderUnavailable", "captureUnavailable",
    "displayUnavailable", "portUnavailable",
})


class StartupProbeFailure(RuntimeError):
    """Secret-free terminal result for the focused startup probe."""


def _validate_startup_failure(observation: Mapping[str, object]) -> None:
    if (
        type(observation) is not dict
        or set(observation) != {
            "stage", "process", "poll", "exit", "knownCode", "privateLogs",
        }
        or observation["stage"] not in _STARTUP_STAGES
        or observation["process"] not in _STARTUP_PROCESSES
        or observation["poll"] not in _STARTUP_POLLS
        or observation["exit"] not in _STARTUP_EXITS
        or observation["knownCode"] not in _STARTUP_CODES
        or observation["privateLogs"] not in {"preserved", "unavailable"}
        or (observation["poll"] == "exited" and observation["process"] == "none")
        or (observation["poll"] == "notStarted" and observation["process"] != "none")
        or (observation["poll"] == "running" and observation["process"] not in {
            "audio", "display", "sunshine",
        })
        or (
            observation["poll"] == "exited"
            and observation["exit"] == "unavailable"
            and observation["process"] != "multiple"
        )
        or (observation["poll"] != "exited" and observation["exit"] != "unavailable")
    ):
        raise StartupProbeFailure("owned Sunshine startup observation is invalid")


def _validate_readiness(readiness: Mapping[str, object]) -> dict[str, object]:
    value = dict(readiness)
    if (
        set(value) != {
            "schemaVersion", "provider", "providerTag", "packageSha256",
            "platform", "capture", "encoder", "codec", "tlsCertificateSha256",
            "mdns", "state", "streamAccepted",
        }
        or value["schemaVersion"] != 1
        or value["provider"] != "Sunshine"
        or value["providerTag"] != SUNSHINE_TAG
        or value["packageSha256"] != SUNSHINE_SHA256
        or value["platform"] != "ubuntu24.04-amd64"
        or value["capture"] != "x11"
        or value["encoder"] != "software"
        or value["codec"] != "h264"
        or value["state"] != "host_ready"
        or value["streamAccepted"] is not False
        or value["mdns"] != {"service": "_nvstream._tcp", "port": 47989}
        or type(value["tlsCertificateSha256"]) is not str
        or re.fullmatch(r"[0-9a-f]{64}", value["tlsCertificateSha256"]) is None
    ):
        raise StartupProbeFailure("owned Sunshine startup readiness is invalid")
    return value


def _write_receipt(destination: Path, payload: Mapping[str, object]) -> None:
    encoded = json.dumps(payload, separators=(",", ":"), sort_keys=True).encode("utf-8") + b"\n"
    if len(encoded) > MAX_RECEIPT_BYTES:
        raise StartupProbeFailure("owned Sunshine startup receipt exceeds its bound")
    descriptor = os.open(
        destination,
        os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_CLOEXEC", 0),
        0o600,
    )
    created = os.fstat(descriptor)
    try:
        if (
            not stat.S_ISREG(created.st_mode)
            or created.st_nlink != 1
            or created.st_uid != os.getuid()
            or stat.S_IMODE(created.st_mode) != 0o600
        ):
            raise OSError("owned Sunshine startup receipt identity is invalid")
        offset = 0
        while offset < len(encoded):
            written = os.write(descriptor, encoded[offset:])
            if type(written) is not int or written <= 0 or written > len(encoded) - offset:
                raise OSError("owned Sunshine startup receipt write failed")
            offset += written
        os.fsync(descriptor)
    except BaseException:
        try:
            current = destination.lstat()
            if (
                stat.S_ISREG(current.st_mode)
                and (current.st_dev, current.st_ino) == (created.st_dev, created.st_ino)
            ):
                destination.unlink()
        except OSError:
            pass
        raise
    finally:
        os.close(descriptor)


def _base_receipt(*, result: str) -> dict[str, object]:
    revision = source_revision(ROOT)
    if re.fullmatch(r"[0-9a-f]{40}", revision) is None:
        raise StartupProbeFailure("owned Sunshine startup source identity is invalid")
    return {
        "schemaVersion": 1,
        "gate": "owned_sunshine_stream_startup_probe",
        "sourceRevision": revision,
        "provider": "Sunshine",
        "providerTag": SUNSHINE_TAG,
        "packageSha256": SUNSHINE_SHA256,
        "result": result,
        "phase": "hostStartup",
        "counts": None,
        "streamAccepted": False,
        "featureAccepted": False,
    }


def run_probe(destination: Path, *, environment: Mapping[str, str]) -> None:
    try:
        with OwnedSunshineHost.start(
            environment=environment,
            stream_profile=True,
        ) as owned:
            readiness = _validate_readiness(owned.public_readiness())
        _write_receipt(destination, {
            **_base_receipt(result="ready"),
            "startup": readiness,
        })
    except HostStartupFailure as error:
        _validate_startup_failure(error.observation)
        _write_receipt(destination, {
            **_base_receipt(result="failed"),
            "startup": dict(error.observation),
        })
        raise StartupProbeFailure("owned Sunshine stream-profile startup failed") from None


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = argparse.ArgumentParser(
        description="Start the real owned F60 stream-profile host without Android."
    )
    parser.add_argument("--receipt", required=True)
    try:
        arguments = parser.parse_args(argv)
        runner_temp = os.environ.get("RUNNER_TEMP")
        destination = Path(arguments.receipt)
        if (
            not runner_temp
            or not destination.is_absolute()
            or destination.parent.resolve() != Path(runner_temp).resolve()
            or destination.name != RECEIPT_NAME
        ):
            raise StartupProbeFailure("owned Sunshine startup receipt path is invalid")
        run_probe(destination, environment=os.environ)
        return 0
    except (HostFailure, OSError, StartupProbeFailure) as error:
        print("F60 startup probe: " + str(error), file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
