"""Offline contract for native managed Seerr acceptance."""

import copy
import importlib
import json
from types import SimpleNamespace

import pytest


def api():
    return importlib.import_module("tool.seerr_managed_ci")


def receipt(module):
    source = module.fixture_source("linux/amd64")
    hashes = module.smoke.source_hashes()
    helper = module.smoke.helper_attestation(
        "sha256:" + "f" * 64,
        {
            "Id": "sha256:" + "f" * 64,
            "Os": "linux",
            "Architecture": "amd64",
            "Config": {"Labels": module.smoke.source_labels("a" * 40, hashes)},
        },
        "linux/amd64",
        "a" * 40,
    )
    return {
        "schemaVersion": 1,
        "result": "seerr_characterized",
        "serviceVersion": "3.4.1",
        "platform": "linux/amd64",
        "sourceCommit": "a" * 40,
        "catalogDigest": source.catalog.digest,
        "seerrManifestDigest": source.image.image.digest,
        "seerrConfigDigest": source.image.image.configDigest,
        "helper": helper,
        "imageState": "ready",
        "networkState": "ready",
        "volumeStates": ["observed_requires_bootstrap"],
        "volumeCount": 1,
        "containerMode": "journaled_managed_v2",
        "containerJournalVersion": 2,
        "containerState": "seerr_container_started",
        "freshStateVerified": True,
        "restartCount": 1,
        "freshStatePersistent": True,
        "installAvailable": False,
    }


def test_fixture_and_receipt_are_exact_and_secret_free():
    module = api()
    source = module.fixture_source("linux/amd64")
    assert source.image.serviceId == "seerr"
    assert len(source.targets) == 1
    assert source.targets[0].kind == "managed_appdata"
    assert source.targets[0].target == "/app/config"

    value = receipt(module)
    assert module.validate_receipt(value, "a" * 40, "linux/amd64") is None
    for field in (
        "serviceVersion",
        "containerState",
        "freshStateVerified",
        "restartCount",
        "freshStatePersistent",
    ):
        damaged = copy.deepcopy(value)
        damaged.pop(field)
        with pytest.raises(module.SeerrManagedCIError):
            module.validate_receipt(damaged, "a" * 40, "linux/amd64")
    serialized = json.dumps(value)
    assert "apiKey" not in serialized and "credential" not in serialized


def test_launch_requires_reviewed_source_and_real_native_runner():
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
        "GITHUB_EVENT_NAME": "pull_request",
        "GITHUB_REF": "refs/pull/148/merge",
        "GITHUB_BASE_REF": "main",
        "PR_HEAD_REPOSITORY": "ersingundem/larenor",
    }
    assert module.validate_launch(base, "Linux", "x86_64", 0) == "linux/amd64"
    for damaged in (
        {**base, "PR_HEAD_REPOSITORY": "fork/larenor"},
        {**base, "GITHUB_WORKFLOW_SHA": "b" * 40},
        {**base, "EXPECTED_PLATFORM": "linux/arm64"},
    ):
        with pytest.raises(module.SeerrManagedCIError):
            module.validate_launch(damaged, "Linux", "x86_64", 0)


def test_characterize_projects_only_closed_native_evidence(monkeypatch):
    module = api()
    expected = receipt(module)
    source = module.fixture_source("linux/amd64")
    binding = ("a" * 40, module.smoke.source_hashes())
    daemon = SimpleNamespace(platform="linux/amd64")
    events = []
    monkeypatch.setattr(module, "fixture_source", lambda _platform: source)
    monkeypatch.setattr(
        module.smoke, "check_source", lambda value: events.append(("source", value[0]))
    )
    monkeypatch.setattr(
        module,
        "_prepare_resources",
        lambda *_args: ("endpoint", expected["volumeStates"]),
    )
    monkeypatch.setattr(
        module.shared,
        "_build_helper",
        lambda *_args: ("sha256:" + "f" * 64, expected["helper"]),
    )
    monkeypatch.setattr(module.shared, "_prepare_volumes", lambda *_args: None)
    monkeypatch.setattr(
        module,
        "_start_verify_restart",
        lambda *_args: SimpleNamespace(
            state="seerr_container_started",
            fresh=True,
            persistent=True,
        ),
    )

    assert module.characterize(daemon, checkout_binding=binding) == expected
    assert events == [("source", "a" * 40), ("source", "a" * 40)]


def test_characterize_closes_unexpected_native_lifecycle_failures(monkeypatch):
    module = api()
    source = module.fixture_source("linux/amd64")
    binding = ("a" * 40, module.smoke.source_hashes())
    daemon = SimpleNamespace(platform="linux/amd64")
    monkeypatch.setattr(module, "fixture_source", lambda _platform: source)
    monkeypatch.setattr(module.smoke, "check_source", lambda _value: None)
    monkeypatch.setattr(
        module, "_prepare_resources", lambda *_args: ("endpoint", ["ready"])
    )
    monkeypatch.setattr(
        module.shared,
        "_build_helper",
        lambda *_args: ("sha256:" + "f" * 64, {}),
    )
    monkeypatch.setattr(module.shared, "_prepare_volumes", lambda *_args: None)
    monkeypatch.setattr(
        module,
        "_start_verify_restart",
        lambda *_args: (_ for _ in ()).throw(RuntimeError("private")),
    )

    with pytest.raises(
        module.SeerrManagedCIError, match="^seerr_native_lifecycle_failed$"
    ):
        module.characterize(daemon, checkout_binding=binding)


def test_runtime_setup_maps_binding_rejection_to_phase_code():
    module = api()
    from larenor_server.plugins.managed_container import ManagedContainerError

    with pytest.raises(
        module.SeerrManagedCIError,
        match="^seerr_runtime_setup_failed$",
    ):
        with module.diagnostic_phase("runtime_setup"):
            raise ManagedContainerError("resources_untrusted")


def test_receipt_verification_never_starts_daemon(tmp_path, monkeypatch, capsys):
    module = api()
    path = tmp_path / "receipt.json"
    path.write_text(json.dumps(receipt(module)))
    monkeypatch.setenv("GITHUB_SHA", "a" * 40)
    monkeypatch.setenv("EXPECTED_PLATFORM", "linux/amd64")
    monkeypatch.setattr(module.smoke, "verify_checkout", lambda _commit: None)
    monkeypatch.setattr(
        module.smoke,
        "EphemeralDaemon",
        lambda: pytest.fail("receipt verification started daemon"),
    )
    assert module.main(["--verify-receipt", str(path)]) == 0
    assert capsys.readouterr().out == "seerr_characterization_receipt_verified\n"
