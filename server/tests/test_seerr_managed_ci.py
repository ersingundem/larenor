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
        "schemaVersion": 2,
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
        "adminState": "verified",
        "adminSessionClosed": True,
        "arrWiringState": "verified",
        "arrServiceIds": ["radarr", "sonarr"],
        "initializationState": "verified",
        "initializationChanged": True,
        "authenticatedReadbackVerified": True,
        "restartCount": 1,
        "freshStatePersistent": True,
        "restartIdempotent": True,
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
        "adminState",
        "adminSessionClosed",
        "arrWiringState",
        "arrServiceIds",
        "initializationState",
        "initializationChanged",
        "authenticatedReadbackVerified",
        "restartCount",
        "freshStatePersistent",
        "restartIdempotent",
    ):
        damaged = copy.deepcopy(value)
        damaged.pop(field)
        with pytest.raises(module.SeerrManagedCIError):
            module.validate_receipt(damaged, "a" * 40, "linux/amd64")
    serialized = json.dumps(value)
    assert "apiKey" not in serialized and "credential" not in serialized
    assert "instanceId" not in serialized and "configurationDigest" not in serialized


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


def test_characterize_projects_only_closed_convergence_evidence(monkeypatch):
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
        "_converge_native_stack",
        lambda *_args: (
            expected["helper"],
            expected["volumeStates"],
            SimpleNamespace(
                state="seerr_container_started",
                fresh=True,
                persistent=True,
                admin_state="verified",
                admin_session_closed=True,
                arr_service_ids=("radarr", "sonarr"),
                initialization_state="verified",
                initialization_changed=True,
                authenticated_readback=True,
                restart_idempotent=True,
            ),
        ),
    )

    assert module.characterize(daemon, checkout_binding=binding) == expected
    assert events == [("source", "a" * 40), ("source", "a" * 40)]


def test_characterize_closes_unexpected_native_convergence_failures(monkeypatch):
    module = api()
    source = module.fixture_source("linux/amd64")
    binding = ("a" * 40, module.smoke.source_hashes())
    daemon = SimpleNamespace(platform="linux/amd64")
    monkeypatch.setattr(module, "fixture_source", lambda _platform: source)
    monkeypatch.setattr(module.smoke, "check_source", lambda _value: None)
    monkeypatch.setattr(
        module,
        "_converge_native_stack",
        lambda *_args: (_ for _ in ()).throw(RuntimeError("private")),
    )

    with pytest.raises(
        module.SeerrManagedCIError, match="^seerr_native_convergence_failed$"
    ):
        module.characterize(daemon, checkout_binding=binding)


def test_native_result_requires_complete_admin_wiring_and_restart_readback():
    module = api()
    valid = {
        "state": "seerr_container_started",
        "fresh": True,
        "persistent": True,
        "admin_state": "verified",
        "admin_session_closed": True,
        "arr_service_ids": ("radarr", "sonarr"),
        "initialization_state": "verified",
        "initialization_changed": True,
        "authenticated_readback": True,
        "restart_idempotent": True,
    }
    result = module._SeerrNativeResult(**valid)
    assert result.arr_service_ids == ("radarr", "sonarr")
    for field, value in (
        ("admin_session_closed", False),
        ("arr_service_ids", ("radarr",)),
        ("authenticated_readback", False),
        ("restart_idempotent", False),
    ):
        damaged = valid | {field: value}
        with pytest.raises(module.SeerrManagedCIError):
            module._SeerrNativeResult(**damaged)


def test_runtime_setup_maps_binding_rejection_to_phase_code():
    module = api()
    from larenor_server.plugins.managed_container import ManagedContainerError

    with pytest.raises(
        module.SeerrManagedCIError,
        match="^seerr_runtime_setup_failed$",
    ):
        with module.diagnostic_phase("runtime_setup"):
            raise ManagedContainerError("resources_untrusted")


def test_bootstrap_diagnostic_is_allowlisted_and_secret_free():
    module = api()
    error = module.SeerrManagedCIError(
        "seerr_bootstrap_failed",
        bootstrap_code="seerr_bootstrap_arr_wiring_failed",
        cause_code="seerr_arr_selection_changed",
        completed_steps=4,
    )
    assert error.diagnostic() == (
        "seerr_bootstrap_failed code=seerr_bootstrap_arr_wiring_failed "
        "cause=seerr_arr_selection_changed completed=4"
    )
    assert "private" not in error.diagnostic()


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
