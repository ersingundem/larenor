#!/usr/bin/python3
"""Owned F08 provider fixture that deliberately reaches cgroup limits."""

import argparse
import errno
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import stat
import time


PROVIDER_ID = "f08-cgroup-stress-v1"
OBSERVATION_TIMEOUT_SECONDS = 8


def _wait_observation(root, dispatch_id, stage):
    """Wait for the owned observer without extending a production deadline."""
    if (
        not isinstance(dispatch_id, str)
        or re.fullmatch(r"[a-f0-9]{32}", dispatch_id) is None
        or stage not in {"start", "observed"}
    ):
        raise ValueError("invalid observation binding")
    info = root.lstat()
    if (
        not stat.S_ISDIR(info.st_mode)
        or info.st_uid != os.geteuid()
        or info.st_mode & 0o077
    ):
        raise ValueError("invalid observation root")
    path = root / f"{dispatch_id}.{stage}"
    deadline = time.monotonic() + OBSERVATION_TIMEOUT_SECONDS
    while time.monotonic() < deadline:
        try:
            value = _read_private(path, 16)
        except FileNotFoundError:
            time.sleep(0.02)
            continue
        if value != b"observed\n":
            raise ValueError("invalid observation acknowledgement")
        return
    raise TimeoutError("owned observation deadline expired")


def _read_private(path, maximum):
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    try:
        info = os.fstat(descriptor)
        if (
            not stat.S_ISREG(info.st_mode)
            or info.st_size > maximum
            or info.st_uid != os.geteuid()
            or info.st_mode & 0o077
        ):
            raise ValueError()
        value = os.read(descriptor, maximum + 1)
        if len(value) != info.st_size:
            raise ValueError()
        return value
    finally:
        os.close(descriptor)


def _exclusive(path, value):
    descriptor = os.open(
        path,
        os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
        0o600,
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


def _descriptor(path):
    value = json.loads(_read_private(path, 4096).decode("ascii"))
    if (
        type(value) is not dict
        or set(value)
        != {
            "schemaVersion",
            "jobId",
            "dispatchId",
            "requestKey",
            "kind",
            "providerId",
            "outputPath",
            "receiptPath",
        }
        or value["schemaVersion"] != 1
        or value["providerId"] != PROVIDER_ID
    ):
        raise ValueError("invalid descriptor")
    return value


def _memory_limit(observation_root, dispatch_id):
    # The observer snapshots hierarchical memory.events before allocation.
    # Normal systemd OOM retirement may terminate this parent too. The child is the
    # only process that allocates beyond MemoryMax; the parent never turns a
    # killed allocation into a successful provider receipt.
    child = os.fork()
    if child == 0:
        Path("/proc/self/oom_score_adj").write_text("1000", encoding="ascii")
        value = bytearray(128 * 1024 * 1024)
        for offset in range(0, len(value), 4096):
            value[offset] = 1
        raise AssertionError(len(value))
    _pid, status = os.waitpid(child, 0)
    if not os.WIFSIGNALED(status) or os.WTERMSIG(status) != signal.SIGKILL:
        raise AssertionError(status)
    _wait_observation(observation_root, dispatch_id, "observed")
    raise SystemExit(73)


def _task_limit(observation_root, dispatch_id):
    children = []
    limited = False
    try:
        for _index in range(32):
            try:
                child = os.fork()
            except OSError as error:
                if error.errno != errno.EAGAIN:
                    raise
                limited = True
                break
            if child == 0:
                while True:
                    signal.pause()
            children.append(child)
        if not limited:
            raise AssertionError("pids limit was not enforced")
        _exclusive(observation_root / f"{dispatch_id}.limited", b"eagain\n")
        # Keep the exact owned tasks alive while the observer proves that the
        # configured leaf is at pids.max and both leaf counters advanced.
        _wait_observation(observation_root, dispatch_id, "observed")
    finally:
        for child in children:
            try:
                os.kill(child, signal.SIGTERM)
            except ProcessLookupError:
                pass
        for child in children:
            try:
                os.waitpid(child, 0)
            except ChildProcessError:
                pass
    raise SystemExit(73)


def _cpu_limit():
    deadline = time.monotonic() + 3
    digest = hashlib.sha256()
    value = 0
    while time.monotonic() < deadline:
        value = (value * 1_664_525 + 1_013_904_223) & 0xFFFFFFFF
        digest.update(value.to_bytes(4, "big"))
    return digest.hexdigest()


def _succeed(descriptor, evidence):
    output = json.dumps(
        {
            "schemaVersion": 1,
            "dispatchId": descriptor["dispatchId"],
            "fixtureDigest": evidence,
        },
        sort_keys=True,
        separators=(",", ":"),
    ).encode("ascii")
    output_digest = hashlib.sha256(output).hexdigest()
    _exclusive(descriptor["outputPath"], output)
    receipt = json.dumps(
        {
            "schemaVersion": 1,
            "jobId": descriptor["jobId"],
            "dispatchId": descriptor["dispatchId"],
            "providerId": descriptor["providerId"],
            "status": "succeeded",
            "outputSha256": output_digest,
            "outputBytes": len(output),
        },
        sort_keys=True,
        separators=(",", ":"),
    ).encode("ascii")
    _exclusive(descriptor["receiptPath"], receipt)
    directory = os.open(
        Path(descriptor["receiptPath"]).parent,
        os.O_RDONLY | os.O_DIRECTORY,
    )
    try:
        os.fsync(directory)
    finally:
        os.close(directory)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--mode", choices=("memory", "tasks", "cpu"), required=True)
    parser.add_argument("--observation-root", type=Path, required=True)
    parser.add_argument("--larenor-job-descriptor", required=True)
    options = parser.parse_args()
    descriptor = _descriptor(options.larenor_job_descriptor)
    dispatch_id = descriptor["dispatchId"]
    _wait_observation(options.observation_root, dispatch_id, "start")
    if options.mode == "memory":
        _memory_limit(options.observation_root, dispatch_id)
    if options.mode == "tasks":
        _task_limit(options.observation_root, dispatch_id)
    evidence = _cpu_limit()
    _wait_observation(options.observation_root, dispatch_id, "observed")
    _succeed(descriptor, evidence)


if __name__ == "__main__":
    main()
