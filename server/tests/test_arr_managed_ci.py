"""Offline contract for native managed Sonarr/Radarr acceptance."""

import copy
import importlib
import json
from types import SimpleNamespace

import pytest


def api():
    return importlib.import_module("tool.arr_managed_ci")


def receipt(module, service="sonarr"):
    source = module.fixture_source("linux/amd64", service)
    hashes = module.smoke.source_hashes()
    helper = module.smoke.helper_attestation(
        "sha256:" + "f" * 64,
        {
            "Id": "sha256:" + "f" * 64,
            "Os": "linux",
            "Architecture": "amd64",
            "Config": {
                "Labels": module.smoke.source_labels("a" * 40, hashes),
            },
        },
        "linux/amd64",
        "a" * 40,
    )
    expected_version = {"sonarr": "4.0.19.2979", "radarr": "6.3.0.10514"}[service]
    return {
        "schemaVersion": 1,
        "result": "arr_characterized",
        "serviceId": service,
        "serviceVersion": expected_version,
        "platform": "linux/amd64",
        "sourceCommit": "a" * 40,
        "catalogDigest": source.catalog.digest,
        "arrManifestDigest": source.image.image.digest,
        "arrConfigDigest": source.image.image.configDigest,
        "helper": helper,
        "imageState": "ready",
        "networkState": "ready",
        "volumeStates": ["observed_requires_bootstrap"] * 2,
        "volumeCount": 2,
        "containerMode": "journaled_managed_v2",
        "containerJournalVersion": 2,
        "configurationState": service + "_config_installed",
        "containerState": service + "_container_started",
        "serviceState": service + "_service_verified",
        "apiKeyVerified": True,
        "restartCount": 1,
        "installAvailable": False,
    }


@pytest.mark.parametrize("service", ["sonarr", "radarr"])
def test_receipt_requires_exact_service_version_and_restart_evidence(service):
    module = api()
    value = receipt(module, service)
    assert module.validate_receipt(value, "a" * 40, "linux/amd64", service) is None
    for field in (
        "serviceId",
        "serviceVersion",
        "configurationState",
        "containerState",
        "serviceState",
        "apiKeyVerified",
        "restartCount",
    ):
        damaged = copy.deepcopy(value)
        damaged.pop(field)
        with pytest.raises(module.ArrManagedCIError):
            module.validate_receipt(damaged, "a" * 40, "linux/amd64", service)
    serialized = json.dumps(value)
    assert '"apiKey":' not in serialized


@pytest.mark.parametrize(
    ("service", "target"),
    [
        ("sonarr", "/config"),
        ("radarr", "/config"),
    ],
)
def test_fixture_selects_one_service_image_appdata_and_shared_library(service, target):
    module = api()
    source = module.fixture_source("linux/amd64", service)
    assert source.image.serviceId == service
    assert len(source.targets) == 2
    assert {item.kind for item in source.targets} == {
        "managed_appdata",
        "managed_library",
    }
    assert target in {item.target for item in source.targets}
    assert "/media" in {item.target for item in source.targets}


def test_launch_requires_exact_service_and_reviewed_source():
    module = api()
    base = {
        "CI": "true",
        "GITHUB_ACTIONS": "true",
        "RUNNER_ENVIRONMENT": "github-hosted",
        "RUNNER_ARCH": "X64",
        "GITHUB_REPOSITORY": "ersingundem/larenor",
        "GITHUB_WORKFLOW_SHA": "a" * 40,
        "GITHUB_SHA": "a" * 40,
        "EXPECTED_PLATFORM": "linux/amd64",
        "EXPECTED_SERVICE": "sonarr",
        "GITHUB_EVENT_NAME": "pull_request",
        "GITHUB_REF": "refs/pull/49/merge",
        "GITHUB_BASE_REF": "main",
        "PR_HEAD_REPOSITORY": "ersingundem/larenor",
    }
    assert module.validate_launch(base, "Linux", "x86_64", 0) == (
        "linux/amd64",
        "sonarr",
    )
    for damaged in (
        {**base, "EXPECTED_SERVICE": "lidarr"},
        {**base, "PR_HEAD_REPOSITORY": "fork/larenor"},
        {**base, "GITHUB_WORKFLOW_SHA": "b" * 40},
    ):
        with pytest.raises(module.ArrManagedCIError):
            module.validate_launch(damaged, "Linux", "x86_64", 0)


def test_characterize_projects_only_closed_native_evidence(monkeypatch):
    module = api()
    expected = receipt(module)
    source = module.fixture_source("linux/amd64", "sonarr")
    binding = ("a" * 40, module.smoke.source_hashes())
    daemon = SimpleNamespace(platform="linux/amd64")
    events = []
    monkeypatch.setattr(module, "fixture_source", lambda _platform, _service: source)
    monkeypatch.setattr(
        module.smoke, "check_source", lambda value: events.append(("source", value[0]))
    )
    monkeypatch.setattr(
        module.shared,
        "_prepare_resources",
        lambda _daemon, _source: ("endpoint", expected["volumeStates"]),
    )
    monkeypatch.setattr(
        module.shared,
        "_build_helper",
        lambda _daemon, _binding: ("sha256:" + "f" * 64, expected["helper"]),
    )
    monkeypatch.setattr(module.shared, "_prepare_volumes", lambda *_args: None)
    result = SimpleNamespace(
        configuration=SimpleNamespace(state="sonarr_config_installed"),
        state="sonarr_container_started",
        service_state="sonarr_service_verified",
    )
    verified = SimpleNamespace(
        state="verified",
        service_id="sonarr",
        readback=SimpleNamespace(version="4.0.19.2979"),
    )
    monkeypatch.setattr(
        module, "_install_and_restart", lambda *_args: (result, verified)
    )

    assert module.characterize(daemon, "sonarr", checkout_binding=binding) == expected
    assert events == [("source", "a" * 40), ("source", "a" * 40)]


def test_run_publishes_only_after_owned_cleanup(monkeypatch, capsys):
    module = api()
    value = receipt(module)
    events = []
    monkeypatch.setenv("GITHUB_SHA", "a" * 40)
    monkeypatch.setattr(
        module, "validate_launch", lambda *_args: ("linux/amd64", "sonarr")
    )
    monkeypatch.setattr(
        module.smoke,
        "capture_source",
        lambda commit: events.append(("capture", commit)) or ("a" * 40, {}),
    )
    monkeypatch.setattr(
        module.smoke,
        "check_source",
        lambda binding: events.append(("recheck", binding[0])),
    )

    class Owned:
        def __enter__(self):
            events.append("enter")
            return self

        def __exit__(self, *_args):
            assert capsys.readouterr().out == ""
            events.append("cleanup")

        def emergency_cleanup(self):
            events.append("emergency")

    monkeypatch.setattr(module.smoke, "EphemeralDaemon", Owned)
    monkeypatch.setattr(
        module,
        "characterize",
        lambda _owner, service, **kwargs: events.append(
            ("native", service, kwargs["checkout_binding"][0])
        )
        or value,
    )

    assert module.main(["--run-ephemeral-ci"]) == 0
    assert events == [
        ("capture", "a" * 40),
        "enter",
        ("native", "sonarr", "a" * 40),
        "cleanup",
        ("recheck", "a" * 40),
    ]
    assert json.loads(capsys.readouterr().out) == value


def test_diagnostic_phase_preserves_only_closed_arr_code():
    module = api()
    from larenor_server.plugins.arr_config_models import (
        ArrConfigurationExecutionError,
    )

    with pytest.raises(module.ArrManagedCIError) as known:
        with module.diagnostic_phase("runtime_install"):
            raise ArrConfigurationExecutionError(
                "arr_config_timeout", uncertain_effect=True
            )
    assert known.value.args == ("arr_config_timeout",)

    class Untrusted(Exception):
        code = "arr_config_timeout"

    with pytest.raises(module.ArrManagedCIError) as closed:
        with module.diagnostic_phase("runtime_install"):
            raise Untrusted("private detail")
    assert closed.value.args == ("arr_runtime_install_failed",)
