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


def _pids_tree(tmp_path, *, leaf_max=2, current=8):
    parent = tmp_path / "parent"
    leaf = parent / "owned.service"
    leaf.mkdir(parents=True)
    (leaf / "pids.max").write_text("8\n", encoding="ascii")
    (leaf / "pids.current").write_text(f"{current}\n", encoding="ascii")
    (leaf / "pids.events").write_text(f"max {leaf_max}\n", encoding="ascii")
    (leaf / "pids.events.local").write_text(
        f"max {leaf_max}\n", encoding="ascii"
    )
    return parent, leaf


def _remove_leaf(leaf):
    for path in leaf.iterdir():
        path.unlink()
    leaf.rmdir()


def _linux_fixture():
    spec = importlib.util.spec_from_file_location(
        "f08_linux_fixture", Path(__file__).with_name("test_f08_cgroup_stress_linux.py"),
    )
    linux = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(linux)
    return linux


def test_pids_limit_accepts_exact_leaf_local_and_hierarchical_delta(tmp_path):
    linux = _linux_fixture()
    _parent, leaf = _pids_tree(tmp_path)
    baseline = linux._pids_limit_baseline(leaf, expected_max=8)
    (leaf / "pids.events").write_text("max 3\n", encoding="ascii")
    (leaf / "pids.events.local").write_text("max 3\n", encoding="ascii")

    assert linux._wait_pids_limit(leaf, baseline, timeout=0.025) == {"max": 1}


def test_pids_attribution_requires_exact_configured_leaf_limit(tmp_path):
    linux = _linux_fixture()
    _parent, leaf = _pids_tree(tmp_path)
    (leaf / "pids.max").write_text("9\n", encoding="ascii")

    with pytest.raises(AssertionError):
        linux._pids_limit_baseline(leaf, expected_max=8)


def test_pids_attribution_rejects_missing_or_recreated_leaf(tmp_path):
    linux = _linux_fixture()
    _parent, leaf = _pids_tree(tmp_path)
    baseline = linux._pids_limit_baseline(leaf, expected_max=8)
    _remove_leaf(leaf)
    with pytest.raises(FileNotFoundError):
        linux._wait_pids_limit(leaf, baseline, timeout=0.025)

    leaf.mkdir()
    (leaf / "pids.max").write_text("8\n", encoding="ascii")
    (leaf / "pids.current").write_text("8\n", encoding="ascii")
    (leaf / "pids.events").write_text("max 3\n", encoding="ascii")
    (leaf / "pids.events.local").write_text("max 3\n", encoding="ascii")
    with pytest.raises(AssertionError):
        linux._wait_pids_limit(leaf, baseline, timeout=0.025)


def test_pids_attribution_requires_current_equal_to_exact_max(tmp_path):
    linux = _linux_fixture()
    _parent, leaf = _pids_tree(tmp_path, current=7)
    baseline = linux._pids_limit_baseline(leaf, expected_max=8)
    (leaf / "pids.events").write_text("max 3\n", encoding="ascii")
    (leaf / "pids.events.local").write_text("max 3\n", encoding="ascii")
    with pytest.raises(AssertionError):
        linux._wait_pids_limit(leaf, baseline, timeout=0.025)


@pytest.mark.parametrize("counter", ["pids.events", "pids.events.local"])
def test_pids_attribution_requires_both_leaf_counter_deltas(tmp_path, counter):
    linux = _linux_fixture()
    _parent, leaf = _pids_tree(tmp_path)
    baseline = linux._pids_limit_baseline(leaf, expected_max=8)
    (leaf / counter).write_text("max 3\n", encoding="ascii")
    with pytest.raises(pytest.fail.Exception, match="counter did not advance"):
        linux._wait_pids_limit(leaf, baseline, timeout=0.025, sleeper=lambda _: None)


@pytest.mark.parametrize("invalid", ["owner", "mode", "symlink", "size", "content"])
def test_limit_marker_is_private_fixed_and_bound_to_owner(tmp_path, invalid):
    linux = _linux_fixture()
    marker = tmp_path / "marker"
    _private(marker, b"eagain\n")
    linux._wait_limit_marker(marker, expected_uid=marker.stat().st_uid, timeout=0.025)
    expected_uid = marker.stat().st_uid
    if invalid == "owner":
        expected_uid += 1
    elif invalid == "mode":
        marker.chmod(0o644)
    elif invalid == "symlink":
        target = tmp_path / "target"
        marker.rename(target)
        marker.symlink_to(target)
    elif invalid == "size":
        _private(marker, b"eagain\nextra")
    else:
        _private(marker, b"foreign")
    with pytest.raises((AssertionError, OSError)):
        linux._wait_limit_marker(marker, expected_uid=expected_uid, timeout=0.025)


@pytest.mark.parametrize("observer_timeout", [False, True])
def test_task_limit_keeps_children_until_marker_is_observed(
    tmp_path, monkeypatch, observer_timeout,
):
    children = iter([101, 102, 103, 104, 105, 106, 107])
    killed = []
    waited = []

    def fork():
        try:
            return next(children)
        except StopIteration:
            raise OSError(fixture.errno.EAGAIN, "bounded") from None

    monkeypatch.setattr(fixture.os, "fork", fork)
    monkeypatch.setattr(fixture.os, "kill", lambda pid, sig: killed.append((pid, sig)))
    monkeypatch.setattr(fixture.os, "waitpid", lambda pid, _flags: waited.append(pid))

    def observed(root, dispatch_id, stage):
        assert stage == "observed"
        assert (root / f"{dispatch_id}.limited").read_bytes() == b"eagain\n"
        assert killed == [] and waited == []
        if observer_timeout:
            raise TimeoutError("bounded")

    monkeypatch.setattr(fixture, "_wait_observation", observed)
    if observer_timeout:
        with pytest.raises(TimeoutError, match="bounded"):
            fixture._task_limit(tmp_path, DISPATCH_ID)
    else:
        with pytest.raises(SystemExit) as stopped:
            fixture._task_limit(tmp_path, DISPATCH_ID)
        assert stopped.value.code == 73
    assert [pid for pid, _signal in killed] == list(range(101, 108))
    assert waited == list(range(101, 108))
