"""Portable owned-fixture coordination; not Linux cgroup acceptance."""

import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import time

import pytest


SOURCE = Path(__file__).parent / "support" / "f08_cgroup_stress_provider.py"
spec = importlib.util.spec_from_file_location("f08_stress_fixture", SOURCE)
fixture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixture)
DISPATCH_ID = "c" * 32


def _private(path, value):
    path.write_bytes(value)
    path.chmod(0o600)


def test_actual_cpu_fixture_waits_for_observer_and_never_invents_acceptance(tmp_path):
    observation = tmp_path / "observation"
    observation.mkdir(mode=0o700)
    descriptor = tmp_path / "descriptor.json"
    output = tmp_path / "output.json"
    receipt = tmp_path / "receipt.json"
    _private(descriptor, json.dumps({
        "schemaVersion": 1,
        "jobId": "a" * 32,
        "dispatchId": DISPATCH_ID,
        "requestKey": "embedding-stress-request",
        "kind": "embedding",
        "providerId": fixture.PROVIDER_ID,
        "outputPath": str(output),
        "receiptPath": str(receipt),
    }).encode("ascii"))
    process = subprocess.Popen(
        [sys.executable, str(SOURCE), "--mode", "cpu", "--observation-root",
         str(observation), "--larenor-job-descriptor", str(descriptor)],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    try:
        time.sleep(0.15)
        assert process.poll() is None
        assert not output.exists() and not receipt.exists()
        _private(observation / f"{DISPATCH_ID}.start", b"observed\n")
        time.sleep(3.2)
        assert process.poll() is None
        assert not output.exists() and not receipt.exists()
        _private(observation / f"{DISPATCH_ID}.observed", b"observed\n")
        assert process.wait(timeout=3) == 0
        value = json.loads(receipt.read_bytes())
        assert value["status"] == "succeeded"
        assert value["dispatchId"] == DISPATCH_ID
        assert value["outputBytes"] == output.stat().st_size
    finally:
        if process.poll() is None:
            process.terminate()
            process.wait(timeout=3)


@pytest.mark.parametrize("invalid", ["mode", "symlink", "content", "dispatch", "stage"])
def test_observation_binding_rejects_unsafe_acknowledgements(tmp_path, invalid):
    root = tmp_path / "observation"
    root.mkdir(mode=0o700)
    path = root / f"{DISPATCH_ID}.observed"
    _private(path, b"observed\n")
    dispatch, stage = DISPATCH_ID, "observed"
    if invalid == "mode":
        path.chmod(0o644)
    elif invalid == "symlink":
        target = tmp_path / "target"
        path.rename(target)
        path.symlink_to(target)
    elif invalid == "content":
        _private(path, b"not observed\n")
    elif invalid == "dispatch":
        dispatch = "../foreign"
    else:
        stage = "unknown"
    with pytest.raises((ValueError, OSError)):
        fixture._wait_observation(root, dispatch, stage)


def test_observer_deadline_does_not_generate_provider_output(tmp_path, monkeypatch):
    tmp_path.chmod(0o700)
    monkeypatch.setattr(fixture, "OBSERVATION_TIMEOUT_SECONDS", 0.025)
    with pytest.raises(TimeoutError):
        fixture._wait_observation(tmp_path, DISPATCH_ID, "start")
    assert list(tmp_path.iterdir()) == []


def test_counter_requires_new_event_not_historical_positive_value(tmp_path):
    spec = importlib.util.spec_from_file_location(
        "f08_linux_fixture", Path(__file__).with_name("test_f08_cgroup_stress_linux.py"),
    )
    linux = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(linux)
    path = tmp_path / "memory.events"
    path.write_text("oom 9\noom_kill 4\n", encoding="ascii")
    assert linux._wait_counter(path, "oom_kill", baseline={"oom": 8, "oom_kill": 3}) == {
        "oom": 1, "oom_kill": 1,
    }
    with pytest.raises(AssertionError):
        linux._wait_counter(path, "oom_kill", baseline={"oom": 10, "oom_kill": 5})
