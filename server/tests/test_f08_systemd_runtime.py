import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time
import uuid
from types import SimpleNamespace

import pytest

from larenor_server.ai_resources.runtime import (
    AiDispatch, AiRuntimeConfig, AiRuntimeError, SystemdAiJobRuntime,
)


class Runner:
    def __init__(self):
        self.calls = []
        self.observation = (
            "LoadState=loaded\nActiveState=active\nSubState=running\n"
            "Result=success\nExecMainStatus=0\nMemoryPeak=67108864\n"
            "CPUUsageNSec=250000000\n"
        )

    def __call__(self, arguments, timeout):
        self.calls.append((arguments, timeout))
        if "--property=Version" in arguments:
            return SimpleNamespace(returncode=0, stdout="Version=257\n")
        if "show" in arguments:
            return SimpleNamespace(returncode=0, stdout=self.observation)
        return SimpleNamespace(returncode=0, stdout="")


def _executable(path):
    path.write_text("#!/bin/sh\nexit 0\n", encoding="ascii")
    path.chmod(0o700)
    return path


def _sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _config(tmp_path, *, manager="user"):
    state = tmp_path / "state"
    state.mkdir(mode=0o700)
    systemd_run = _executable(tmp_path / "systemd-run")
    systemctl = _executable(tmp_path / "systemctl")
    provider = _executable(tmp_path / "provider")
    model = tmp_path / "fixture.gguf"
    model.write_bytes(b"synthetic model identity")
    model.chmod(0o600)
    source = tmp_path / "runtime.json"
    source.write_text(json.dumps({
        "schemaVersion": 1,
        "manager": manager,
        "systemdRun": str(systemd_run),
        "systemctl": str(systemctl),
        "stateRoot": str(state),
        "maxRuntimeSeconds": 300,
        "maxTasks": 12,
        "providers": [{
            "kind": "vision",
            "providerId": "fixture-vision-v1",
            "executionMode": "standalone",
            "executable": str(provider),
            "executableSha256": _sha(provider),
            "arguments": ["--fixed-model", "fixture-v1"],
            "artifacts": [{"path": str(model), "sha256": _sha(model)}],
        }],
    }), encoding="utf-8")
    source.chmod(0o600)
    return source, state


def _dispatch():
    return AiDispatch(
        "1" * 32, "2" * 32, "vision-work-00000001", "vision", 64, 30,
    )


def test_fixed_provider_uses_systemd_cgroup_limits_and_durable_descriptor(tmp_path):
    source, state = _config(tmp_path)
    runner = Runner()
    runtime = SystemdAiJobRuntime(
        AiRuntimeConfig.load(source), runner=runner, platform="linux",
    )
    observation = runtime.start(_dispatch())
    assert observation.phase == "running"
    start = next(call for call, _timeout in runner.calls if str(call[0]).endswith("systemd-run"))
    assert "--property=CPUQuota=30%" in start
    assert f"--property=MemoryMax={64 * 1_048_576}" in start
    assert "--property=MemorySwapMax=0" in start
    assert "--property=TasksMax=12" in start
    assert "--property=KillMode=control-group" in start
    assert "--property=ProtectKernelModules=yes" not in start
    assert f"--property=InaccessiblePaths=/run/user/{os.geteuid()}/bus" in start
    assert "--property=RemainAfterExit=yes" in start
    assert f"--property=BindPaths={state}" in start
    assert any(value.startswith("--property=BindReadOnlyPaths=")
               for value in start)
    assert "--unit=larenor-ai-" + "2" * 32 + ".service" in start
    separator = start.index("--")
    assert start[separator + 1].endswith("provider")
    assert start[separator + 2:separator + 4] == ("--fixed-model", "fixture-v1")
    descriptor = state / ("2" * 32 + ".json")
    assert descriptor.stat().st_mode & 0o777 == 0o600
    assert json.loads(descriptor.read_text()) == {
        "schemaVersion": 1,
        "jobId": "1" * 32,
        "dispatchId": "2" * 32,
        "requestKey": "vision-work-00000001",
        "kind": "vision",
        "providerId": "fixture-vision-v1",
        "outputPath": str(state / ("2" * 32 + ".output")),
        "receiptPath": str(state / ("2" * 32 + ".receipt")),
    }


def test_system_manager_keeps_kernel_module_capability_bounding_set_drop(tmp_path):
    source, _state = _config(tmp_path, manager="system")
    runner = Runner()
    runtime = SystemdAiJobRuntime(
        AiRuntimeConfig.load(source), runner=runner, platform="linux",
    )
    runtime.start(_dispatch())
    start = next(
        call for call, _timeout in runner.calls if str(call[0]).endswith("systemd-run")
    )
    assert "--property=ProtectKernelModules=yes" in start
    assert not any(value == "--user" for value in start)


def test_observation_reports_actual_terminal_metrics_and_cancel_uses_exact_unit(tmp_path):
    source, state = _config(tmp_path)
    runner = Runner()
    runtime = SystemdAiJobRuntime(
        AiRuntimeConfig.load(source), runner=runner, platform="linux",
    )
    runner.observation = (
        "LoadState=loaded\nActiveState=active\nSubState=exited\n"
        "Result=success\nExecMainStatus=0\nMemoryPeak=68157440\n"
        "CPUUsageNSec=251000000\n"
    )
    output = b"actual provider output"
    output_hash = hashlib.sha256(output).hexdigest()
    output_path = state / ("2" * 32 + ".output")
    receipt_path = state / ("2" * 32 + ".receipt")
    output_path.write_bytes(output)
    receipt_path.write_text(json.dumps({
        "schemaVersion": 1,
        "jobId": "1" * 32,
        "dispatchId": "2" * 32,
        "providerId": "fixture-vision-v1",
        "status": "succeeded",
        "outputSha256": output_hash,
        "outputBytes": len(output),
    }), encoding="ascii")
    output_path.chmod(0o600)
    receipt_path.chmod(0o600)
    observed = runtime.observe(_dispatch())
    assert (observed.phase, observed.result_code, observed.exit_code) == (
        "succeeded", "succeeded", 0)
    assert (observed.memory_peak_mb, observed.cpu_millis) == (65, 251)
    assert (observed.output_sha256, observed.output_bytes) == (
        output_hash, len(output))
    runtime.cancel(_dispatch())
    stop = next(call for call, _timeout in runner.calls if "stop" in call)
    assert stop[-1] == "larenor-ai-" + "2" * 32 + ".service"


def test_runtime_is_unavailable_off_linux_and_rejects_mutable_catalog(tmp_path):
    source, _state = _config(tmp_path)
    runtime = SystemdAiJobRuntime(
        AiRuntimeConfig.load(source), runner=Runner(), platform="darwin",
    )
    assert runtime.available() is False
    os.chmod(source, 0o644)
    with pytest.raises(AiRuntimeError, match="invalid_runtime_configuration"):
        AiRuntimeConfig.load(source)


def test_user_manager_uses_only_the_exact_runtime_bus_environment(tmp_path):
    source, _state = _config(tmp_path)
    runtime = SystemdAiJobRuntime(AiRuntimeConfig.load(source), platform="linux")
    assert runtime._runner.environment == {
        "PATH": "/usr/bin:/bin",
        "LANG": "C",
        "LC_ALL": "C",
        "XDG_RUNTIME_DIR": f"/run/user/{os.geteuid()}",
        "DBUS_SESSION_BUS_ADDRESS": f"unix:path=/run/user/{os.geteuid()}/bus",
    }


def test_worker_becomes_unavailable_when_allowlisted_artifact_identity_changes(tmp_path):
    source, _state = _config(tmp_path)
    config = AiRuntimeConfig.load(source)
    runtime = SystemdAiJobRuntime(config, runner=Runner(), platform="linux")
    assert runtime.available() is True
    artifact = config.providers[0].artifacts[0][0]
    artifact.write_bytes(b"changed model identity")
    artifact.chmod(0o600)
    assert runtime.available() is False


def test_existing_descriptor_must_match_exact_dispatch(tmp_path):
    source, state = _config(tmp_path)
    runtime = SystemdAiJobRuntime(
        AiRuntimeConfig.load(source), runner=Runner(), platform="linux",
    )
    (state / ("2" * 32 + ".json")).write_text("{}", encoding="ascii")
    with pytest.raises(AiRuntimeError, match="invalid_runtime_response"):
        runtime.start(_dispatch())


def test_standalone_provider_process_writes_verified_output_and_receipt(tmp_path):
    source, state = _config(tmp_path)
    provider = tmp_path / "provider"
    shutil.copyfile(
        Path(__file__).parent / "support" / "f08_standalone_provider.py",
        provider,
    )
    provider.chmod(0o700)
    catalog = json.loads(source.read_text(encoding="utf-8"))
    catalog["providers"][0] = {
        "kind": "vision",
        "providerId": "f08-boundary-fixture-v1",
        "executionMode": "standalone",
        "executable": str(provider),
        "executableSha256": _sha(provider),
        "arguments": ["--fixed-fixture"],
        "artifacts": [],
    }
    source.write_text(json.dumps(catalog), encoding="utf-8")
    runner = Runner()
    runtime = SystemdAiJobRuntime(
        AiRuntimeConfig.load(source), runner=runner, platform="linux",
    )
    descriptor = runtime._descriptor(_dispatch(), runtime._providers["vision"])
    result = subprocess.run(
        [str(provider), "--fixed-fixture", "--larenor-job-descriptor",
         str(descriptor)],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
        timeout=10,
    )
    assert result.returncode == 0, result.stderr.decode(errors="replace")
    runner.observation = (
        "LoadState=loaded\nActiveState=inactive\nSubState=dead\n"
        "Result=success\nExecMainStatus=0\nMemoryPeak=3145728\n"
        "CPUUsageNSec=1000000\n"
    )
    observation = runtime.observe(_dispatch())
    assert observation.phase == "succeeded"
    output = state / ("2" * 32 + ".output")
    assert observation.output_sha256 == hashlib.sha256(output.read_bytes()).hexdigest()
    assert observation.output_bytes == output.stat().st_size
    runtime.release(_dispatch())
    assert not output.exists()
    assert not (state / ("2" * 32 + ".receipt")).exists()
    assert not descriptor.exists()


@pytest.mark.skipif(
    sys.platform != "linux"
    or os.environ.get("LARENOR_F08_SYSTEMD_ACCEPTANCE") != "1",
    reason="explicit Linux systemd acceptance gate",
)
def test_actual_systemd_cgroup_runs_standalone_provider_and_reads_receipt(tmp_path):
    systemd_run = shutil.which("systemd-run")
    systemctl = shutil.which("systemctl")
    if systemd_run is None or systemctl is None:
        pytest.skip("systemd tools unavailable")
    provider = tmp_path / "f08-standalone-provider"
    shutil.copyfile(
        Path(__file__).parent / "support" / "f08_standalone_provider.py",
        provider,
    )
    provider.chmod(0o700)
    state = tmp_path / "state"
    state.mkdir(mode=0o700)
    source = tmp_path / "runtime.json"
    manager = os.environ.get("LARENOR_F08_SYSTEMD_MANAGER", "user")
    assert manager in {"user", "system"}
    source.write_text(json.dumps({
        "schemaVersion": 1,
        "manager": manager,
        "systemdRun": systemd_run,
        "systemctl": systemctl,
        "stateRoot": str(state),
        "maxRuntimeSeconds": 30,
        "maxTasks": 8,
        "providers": [{
            "kind": "vision",
            "providerId": "f08-boundary-fixture-v1",
            "executionMode": "standalone",
            "executable": str(provider),
            "executableSha256": _sha(provider),
            "arguments": ["--fixed-fixture"],
            "artifacts": [],
        }],
    }), encoding="utf-8")
    source.chmod(0o600)
    runtime = SystemdAiJobRuntime(AiRuntimeConfig.load(source))
    if not runtime.available():
        pytest.fail(f"{manager} systemd manager or provider identity unavailable")
    dispatch = AiDispatch(
        uuid.uuid4().hex, uuid.uuid4().hex, "linux-cgroup-gate-0001",
        "vision", 64, 30,
    )
    manager_arguments = ["--user"] if manager == "user" else []
    try:
        observation = runtime.start(dispatch)
        limits = subprocess.run(
            [systemctl, *manager_arguments, "show", runtime._unit(dispatch),
             "--property=MemoryMax,MemorySwapMax,TasksMax,CPUQuotaPerSecUSec"],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
            text=True,
            timeout=10,
        )
        assert limits.returncode == 0, limits.stderr
        properties = dict(
            line.split("=", 1)
            for line in limits.stdout.splitlines() if "=" in line
        )
        assert properties == {
            "CPUQuotaPerSecUSec": "300ms",
            "MemoryMax": str(dispatch.memory_mb * 1_048_576),
            "MemorySwapMax": "0",
            "TasksMax": "8",
        }
        deadline = time.monotonic() + 20
        while (observation.phase in {"starting", "running"}
               and time.monotonic() < deadline):
            time.sleep(0.1)
            observation = runtime.observe(dispatch)
        assert observation.phase == "succeeded"
        assert observation.result_code == "succeeded"
        assert observation.exit_code == 0
        assert observation.memory_peak_mb is not None
        assert 0 < observation.memory_peak_mb <= 2**31 - 1, observation.memory_peak_mb
        assert observation.cpu_millis is not None and observation.cpu_millis > 0
        assert observation.output_sha256 is not None
    finally:
        runtime.release(dispatch)
    assert not any(state.iterdir())
    release_deadline = time.monotonic() + 5
    while True:
        released = subprocess.run(
            [systemctl, *manager_arguments, "show", runtime._unit(dispatch),
             "--property=LoadState"],
            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, check=False, text=True, timeout=10,
        )
        if (released.returncode != 0
                or released.stdout.strip() == "LoadState=not-found"):
            break
        if time.monotonic() >= release_deadline:
            pytest.fail("transient systemd unit was not collected after release")
        time.sleep(0.1)
