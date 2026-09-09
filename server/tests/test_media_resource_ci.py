"""Closed receipt validation for the native resource acceptance workflow."""

import copy
import json
import signal

import pytest


def environment():
    return {"CI": "true", "GITHUB_ACTIONS": "true",
            "RUNNER_ENVIRONMENT": "github-hosted", "RUNNER_ARCH": "X64",
            "GITHUB_SHA": "a" * 40, "GITHUB_WORKFLOW_SHA": "a" * 40,
            "GITHUB_EVENT_NAME": "workflow_dispatch", "GITHUB_REF": "refs/heads/main",
            "GITHUB_REPOSITORY": "ersingundem/larenor",
            "EXPECTED_PLATFORM": "linux/amd64"}


def receipt():
    from tool.jellyfin_storage_smoke import fixture_source
    source = fixture_source("linux/amd64")
    image = next(item for item in source.plan.resources
                 if item.kind == "ensure_image" and item.serviceId == "jellyfin")
    return {
        "schemaVersion": 1,
        "result": "resources_ready",
        "platform": "linux/amd64",
        "sourceCommit": "a" * 40,
        "catalogDigest": source.catalog.digest,
        "imageConfigDigest": image.image.configDigest,
        "imageState": "ready",
        "networkState": "ready",
        "networkIdentitySha256": "d" * 64,
        "resourceKinds": ["ensure_image", "prepare_control_network"],
        "resourceCount": 2,
        "journalRestartCount": 1,
        "containerOperations": 0,
        "installAvailable": False,
        "sourceHashes": {"tool/media_resource_smoke.py": "e" * 64},
    }


def test_receipt_validator_accepts_closed_exact_value(monkeypatch):
    from tool import media_resource_ci as module
    monkeypatch.setattr(module, "source_hashes", lambda: receipt()["sourceHashes"])
    module.validate_receipt(receipt(), "a" * 40, "linux/amd64")


@pytest.mark.parametrize("path,value", [
    (("result",), "installed"), (("platform",), "linux/arm64"),
    (("resourceCount",), True), (("journalRestartCount",), 0),
    (("containerOperations",), 1), (("installAvailable",), True),
    (("resourceKinds",), ["prepare_control_network", "ensure_image"]),
    (("networkIdentitySha256",), "private-network-id"),
])
def test_receipt_validator_rejects_overclaim_or_shape_change(monkeypatch, path, value):
    from tool import media_resource_ci as module
    candidate = copy.deepcopy(receipt())
    candidate[path[0]] = value
    monkeypatch.setattr(module, "source_hashes", lambda: receipt()["sourceHashes"])
    with pytest.raises(module.ResourceCIError, match="^resource_characterization_evidence_invalid$"):
        module.validate_receipt(candidate, "a" * 40, "linux/amd64")


def test_receipt_validator_rejects_unknown_or_changed_source_hash(monkeypatch):
    from tool import media_resource_ci as module
    monkeypatch.setattr(module, "source_hashes", lambda: receipt()["sourceHashes"])
    for candidate in (receipt() | {"extra": True}, receipt() | {"sourceHashes": {"x": "e" * 64}}):
        with pytest.raises(module.ResourceCIError, match="^resource_characterization_evidence_invalid$"):
            module.validate_receipt(candidate, "a" * 40, "linux/amd64")


@pytest.mark.parametrize("field,value", [
    ("GITHUB_REF", "refs/heads/unreviewed"),
    ("GITHUB_EVENT_NAME", "push"),
    ("GITHUB_REPOSITORY", "other/fork"),
    ("GITHUB_WORKFLOW_SHA", "b" * 40),
    ("EXPECTED_PLATFORM", "linux/arm64"),
    ("RUNNER_ENVIRONMENT", "self-hosted"),
])
def test_launch_rejects_nonmanual_or_rebound_source(field, value):
    from tool import media_resource_ci as module
    candidate = environment() | {field: value}
    with pytest.raises(module.ResourceCIError,
                       match="^resource_characterization_evidence_invalid$"):
        module.validate_launch(candidate, "Linux", "x86_64", 0)


def test_launch_accepts_exact_native_architectures():
    from tool import media_resource_ci as module
    assert module.validate_launch(environment(), "Linux", "x86_64", 0) == "linux/amd64"
    arm = environment() | {"RUNNER_ARCH": "ARM64", "EXPECTED_PLATFORM": "linux/arm64"}
    assert module.validate_launch(arm, "Linux", "aarch64", 0) == "linux/arm64"


@pytest.mark.parametrize("raw", [
    b"{}", b"{}" * 20000, b'{"schemaVersion":1,"schemaVersion":1}',
    b'{"x":NaN}', b"\xff",
])
def test_verifier_rejects_bounded_duplicate_or_invalid_json(tmp_path, monkeypatch, raw, capsys):
    from tool import media_resource_ci as module
    path = tmp_path / "receipt.json"
    path.write_bytes(raw)
    monkeypatch.setenv("GITHUB_SHA", "a" * 40)
    monkeypatch.setenv("EXPECTED_PLATFORM", "linux/amd64")
    monkeypatch.setattr(module.smoke, "verify_checkout", lambda _commit: None)
    assert module.main(["--verify-receipt", str(path)]) == 1
    output = capsys.readouterr()
    assert output.out == ""
    assert output.err == "resource_characterization_evidence_invalid\n"


def test_verifier_accepts_exact_receipt_without_starting_engine(tmp_path, monkeypatch, capsys):
    from tool import media_resource_ci as module
    path = tmp_path / "receipt.json"
    path.write_text(json.dumps(receipt()))
    monkeypatch.setenv("GITHUB_SHA", "a" * 40)
    monkeypatch.setenv("EXPECTED_PLATFORM", "linux/amd64")
    monkeypatch.setattr(module.smoke, "verify_checkout", lambda _commit: None)
    monkeypatch.setattr(module, "source_hashes", lambda: receipt()["sourceHashes"])
    monkeypatch.setattr(module.owned, "EphemeralDaemon",
                        lambda: pytest.fail("receipt verification started Engine"))
    assert module.main(["--verify-receipt", str(path)]) == 0
    assert capsys.readouterr().out == "resource_characterization_receipt_verified\n"


@pytest.mark.parametrize("arguments", [[], ["--run"],
    ["--run-ephemeral-ci", "--socket", "/foreign.sock"]])
def test_cli_has_no_implicit_or_socket_selected_launch(arguments, monkeypatch, capsys):
    from tool import media_resource_ci as module
    monkeypatch.setattr(module, "run", lambda: pytest.fail("invalid CLI started fixture"))
    assert module.main(arguments) == 1
    assert capsys.readouterr().out == ""


def test_signal_uses_only_owned_emergency_cleanup_before_context_exit(monkeypatch, capsys):
    from tool import media_resource_ci as module
    events, handlers = [], {}

    class Owned:
        def __enter__(self):
            events.append("enter")
            return self
        def emergency_cleanup(self):
            events.append("emergency")
        def __exit__(self, *_args):
            events.append("exit")

    monkeypatch.setenv("GITHUB_SHA", "a" * 40)
    monkeypatch.setattr(module, "validate_launch", lambda *_args: "linux/amd64")
    monkeypatch.setattr(module.smoke, "capture_source", lambda _commit: ("a" * 40, {}))
    monkeypatch.setattr(module.owned, "EphemeralDaemon", Owned)
    monkeypatch.setattr(module.signal, "getsignal", lambda _sig: signal.SIG_DFL)
    monkeypatch.setattr(module.signal, "signal",
                        lambda sig, handler: handlers.__setitem__(sig, handler))
    monkeypatch.setattr(module.signal, "alarm", lambda seconds: events.append(("alarm", seconds)))

    def interrupted(*_args, **_kwargs):
        handlers[signal.SIGTERM](signal.SIGTERM, None)

    monkeypatch.setattr(module.smoke, "characterize", interrupted)
    assert module.main(["--run-ephemeral-ci"]) == 1
    assert events.index("emergency") < events.index("exit")
    assert ("alarm", 1200) in events and events[-1] == ("alarm", 0)
    assert capsys.readouterr().err == "resource_characterization_cancelled\n"
