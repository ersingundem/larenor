#!/usr/bin/python3
"""Deterministic process fixture for the opt-in F08 Linux cgroup gate.

This exercises the standalone provider receipt contract.  It is not an AI
provider and is never selected by application production configuration.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import stat


def _read_private(path, maximum):
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    try:
        info = os.fstat(descriptor)
        if (not stat.S_ISREG(info.st_mode) or info.st_size > maximum
                or info.st_uid != os.geteuid() or info.st_mode & 0o077):
            raise ValueError()
        value = os.read(descriptor, maximum + 1)
        if len(value) != info.st_size:
            raise ValueError()
        return value
    finally:
        os.close(descriptor)


def _exclusive(path, value):
    descriptor = os.open(
        path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600,
    )
    try:
        offset = 0
        while offset < len(value):
            written = os.write(descriptor, value[offset:])
            if written <= 0:
                raise OSError()
            offset += written
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--fixed-fixture", action="store_true", required=True)
    parser.add_argument("--larenor-job-descriptor", required=True)
    options = parser.parse_args()
    descriptor = json.loads(
        _read_private(options.larenor_job_descriptor, 4096).decode("ascii"),
    )
    if (type(descriptor) is not dict
            or set(descriptor) != {
                "schemaVersion", "jobId", "dispatchId", "requestKey", "kind",
                "providerId", "outputPath", "receiptPath",
            }
            or descriptor["schemaVersion"] != 1
            or descriptor["providerId"] != "f08-boundary-fixture-v1"):
        raise ValueError("invalid descriptor")

    # Real CPU work and allocation make systemd's accounting nonzero without
    # pretending this fixture performs inference.
    working = bytearray(2 * 1024 * 1024)
    accumulator = 0
    for value in range(250_000):
        accumulator = (accumulator + value * 31) & 0xFFFFFFFF
    working[0:4] = accumulator.to_bytes(4, "big")
    output = json.dumps({
        "schemaVersion": 1,
        "dispatchId": descriptor["dispatchId"],
        "fixtureDigest": hashlib.sha256(working).hexdigest(),
    }, sort_keys=True, separators=(",", ":")).encode("ascii")
    output_digest = hashlib.sha256(output).hexdigest()
    _exclusive(descriptor["outputPath"], output)
    receipt = json.dumps({
        "schemaVersion": 1,
        "jobId": descriptor["jobId"],
        "dispatchId": descriptor["dispatchId"],
        "providerId": descriptor["providerId"],
        "status": "succeeded",
        "outputSha256": output_digest,
        "outputBytes": len(output),
    }, sort_keys=True, separators=(",", ":")).encode("ascii")
    _exclusive(descriptor["receiptPath"], receipt)
    directory = os.open(
        Path(descriptor["receiptPath"]).parent, os.O_RDONLY | os.O_DIRECTORY,
    )
    try:
        os.fsync(directory)
    finally:
        os.close(directory)


if __name__ == "__main__":
    main()
