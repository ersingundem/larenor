from __future__ import annotations

import importlib
import json
import sys
from pathlib import Path
from types import SimpleNamespace

import pytest


ROOT = Path(__file__).resolve().parents[2]


def modules():
    for name in ("f62_gateway_linux_probe", "f62_rdpgw_owned_fixture"):
        sys.modules.pop(name, None)
    sys.path.insert(0, str(ROOT / "tool"))
    try:
        owned = importlib.import_module("f62_rdpgw_owned_fixture")
        probe = importlib.import_module("f62_gateway_linux_probe")
    finally:
        sys.path.remove(str(ROOT / "tool"))
    return probe, owned


@pytest.mark.parametrize(
    ("phase", "raw", "expected"),
    (
        ("configure", b"Could NOT find SafeDependency", "missingDependency"),
        ("configure", b"Could not find a package configuration file provided by SafeDependency", "missingDependency"),
        ("configure", b"CMake Error at owned source", "configurationError"),
        ("configure", b"target not found after source validation", "commandFailed"),
        ("configure", b"command returned nonzero", "commandFailed"),
        ("compile", b"owned.c:4:2: fatal error: header.h: No such file or directory", "missingHeader"),
        ("compile", b"owned.c:4:2: error: invalid use", "compilerError"),
        ("compile", b"undefined reference to owned_symbol", "linkerError"),
        ("compile", b"c++: fatal error: Killed signal terminated program", "resourceTerminated"),
        ("compile", b"command returned nonzero", "commandFailed"),
    ),
)
def test_failure_classifier_is_closed(phase: str, raw: bytes, expected: str) -> None:
    probe, _ = modules()
    assert probe._classify_build_failure(phase, raw) == expected
    assert expected in probe.BUILD_FAILURE_CODES


def test_failed_build_writes_only_source_bound_receipt(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch,
) -> None:
    probe, owned = modules()
    revision = "a" * 40
    monkeypatch.setattr(probe, "source_revision", lambda _: revision)
    command = tmp_path / "compiler"
    command.write_text(
        "#!/bin/sh\n"
        "printf '%s\\n' '/private/host/shadow_owned_rdpdr.c:507:10: error: "
        "struct secret has no member named private_token'\n"
        "exit 7\n"
    )
    command.chmod(0o700)
    log = tmp_path / "compile.log"
    receipt = tmp_path / "failure.json"
    with pytest.raises(probe.ProbeError):
        probe._run_build(
            [str(command)], cwd=tmp_path, log=log, timeout=5,
            phase="compile", failure_receipt=receipt,
        )
    value = json.loads(receipt.read_text())
    assert set(value) == probe.BUILD_FAILURE_RECEIPT_KEYS
    assert value["runnerSourceRevision"] == revision
    assert value["phase"] == "compile"
    assert value["schemaVersion"] == 2
    assert value["failureCode"] == "compilerError"
    assert value["compilerSource"] == "ownedRdpdr"
    assert value["compilerLine"] == 507
    assert value["compilerErrorClass"] == "missingMember"
    assert value["exitCode"] == 7
    assert value["featureAccepted"] is False
    encoded = receipt.read_text()
    assert "shadow_owned_rdpdr.c" not in encoded
    assert "private_token" not in encoded
    assert "/private/host" not in encoded
    assert receipt.stat().st_mode & 0o777 == 0o600
    assert log.stat().st_mode & 0o777 == 0o600


def test_successful_build_does_not_create_failure_receipt(tmp_path: Path) -> None:
    probe, _ = modules()
    command = tmp_path / "compiler"
    command.write_text("#!/bin/sh\nexit 0\n")
    command.chmod(0o700)
    receipt = tmp_path / "failure.json"
    probe._run_build(
        [str(command)], cwd=tmp_path, log=tmp_path / "compile.log", timeout=5,
        phase="compile", failure_receipt=receipt,
    )
    assert not receipt.exists()


@pytest.mark.parametrize(
    ("raw", "expected"),
    (
        (
            b"/tmp/private/shadow_owned_rdpdr.c:507:10: error: "
            b"struct private has no member named secret",
            ("ownedRdpdr", 507, "missingMember"),
        ),
        (
            b"/tmp/private/shadow_channels.c:44:3: error: call to undeclared "
            b"function 'private_secret'",
            ("shadowChannels", 44, "undeclaredIdentifier"),
        ),
        (
            b"/tmp/private/shadow.h:139:2: error: incompatible pointer types "
            b"from private hostname",
            ("shadowPublicHeader", 139, "incompatibleType"),
        ),
        (
            b"/tmp/private/shadow_owned_rdpdr.c:9999:2: error: private out of bounds",
            (None, None, None),
        ),
        (
            b"/tmp/private/unreviewed.c:3:2: error: private source",
            (None, None, None),
        ),
        (
            b"/tmp/private/shadow_owned_rdpdr.c:507:2: error:",
            (None, None, None),
        ),
        (
            b"undefined reference to `private_secret'",
            (None, None, "linkUndefined"),
        ),
    ),
)
def test_compiler_diagnostic_is_finite_source_bound(
    raw: bytes, expected: tuple[str | None, int | None, str | None]
) -> None:
    probe, _ = modules()
    assert probe._compiler_diagnostic(raw) == expected


def test_compiler_diagnostic_handles_non_ascii_without_decode() -> None:
    probe, _ = modules()
    raw = (
        b"/tmp/private/shadow_owned_rdpdr.c:353:7: error: too few arguments "
        b"for private \xff symbol"
    )
    assert probe._compiler_diagnostic(raw) == ("ownedRdpdr", 353, "callSignature")


@pytest.mark.parametrize(
    "diagnostic",
    (
        ("ownedRdpdr", 554, "other"),
        ("ownedRdpdr", 507, None),
        (None, None, "missingMember"),
        ("ownedRdpdr", 507, "linkUndefined"),
    ),
)
def test_failure_receipt_rejects_unbound_compiler_tuple(
    tmp_path: Path,
    diagnostic: tuple[str | None, int | None, str | None],
) -> None:
    probe, _ = modules()
    log = tmp_path / "compile.log"
    log.write_bytes(b"private diagnostic input")
    receipt = tmp_path / "failure.json"
    with pytest.raises(probe.ProbeError):
        probe._write_build_failure(
            receipt,
            phase="compile",
            failure_code="compilerError",
            exit_code=1,
            log=log,
            compiler_diagnostic=diagnostic,
        )
    assert not receipt.exists()


def test_cleanup_preparation_repairs_only_owned_tree(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, capsys,
) -> None:
    _, owned = modules()
    root = tmp_path / "owned"
    nested = root / "build/gomodcache/module"
    nested.mkdir(parents=True)
    file = nested / "source.go"
    file.write_text("package owned\n")
    outside = tmp_path / "outside"
    outside.write_text("unchanged")
    outside.chmod(0o400)
    link = nested / "external"
    link.symlink_to(outside)
    for directory in (nested, nested.parent, nested.parent.parent):
        directory.chmod(0o500)
    root.chmod(0o700)
    file.chmod(0o400)
    monkeypatch.setattr(owned, "require_owned_linux", lambda: None)
    owned.prepare_workspace_cleanup(SimpleNamespace(workspace=str(root)))
    assert file.stat().st_mode & 0o777 == 0o600
    assert nested.stat().st_mode & 0o777 == 0o700
    assert link.is_symlink()
    assert outside.stat().st_mode & 0o777 == 0o400
    assert json.loads(capsys.readouterr().out) == {"state": "cleanupPrepared"}


def test_workflow_preserves_receipt_before_owned_cleanup() -> None:
    source = (ROOT / ".github/workflows/server-test.yml").read_text()
    copy = source.index("f62-gateway-build-failure.json")
    network_cleanup = source.index("f62_rdpgw_owned_fixture.py cleanup", copy)
    prepare = source.index("prepare-cleanup", network_cleanup)
    remove = source.index('rm -rf --one-file-system "$LARENOR_F62_PROBE_ROOT"', prepare)
    upload = source.index("Preserve only the closed build failure receipt", remove)
    assert copy < network_cleanup < prepare < remove < upload
    assert "if: failure() && hashFiles('test-results/f62-gateway-build-failure.json') != ''" in source


def test_current_failure_is_not_overclaimed() -> None:
    doc = (ROOT / "docs/testing/f62-gateway-build-diagnostic-2026-10-03.md").read_text()
    assert "configure-versus-compile cause is not recoverable" in doc
    assert "does not identify the failing compiler input" in " ".join(doc.split())
    assert "same-SHA rerun" in doc


@pytest.mark.parametrize("invalid_exit", [True, False])
def test_failure_receipt_rejects_boolean_exit_code(tmp_path: Path, invalid_exit: bool) -> None:
    probe, _ = modules()
    log = tmp_path / "compile.log"
    log.write_bytes(b"private diagnostic input")
    receipt = tmp_path / "failure.json"
    with pytest.raises(probe.ProbeError):
        probe._write_build_failure(
            receipt, phase="compile", failure_code="commandFailed",
            exit_code=invalid_exit, log=log,
        )
    assert not receipt.exists()


def test_truncated_compiler_message_does_not_publish_a_tuple():
    probe, _ = modules()
    raw = b"/private/source/shadow_owned_rdpdr.c:507:2: error: " + b"x" * 513 + b"\n"
    assert probe._compiler_diagnostic(raw) == (None, None, None)


def test_missing_line_in_bound_source_tuple_fails_closed(tmp_path):
    probe, _ = modules()
    log = tmp_path / "compile.log"
    log.write_bytes(b"private input")
    with pytest.raises(probe.ProbeError):
        probe._write_build_failure(
            tmp_path / "failure.json", phase="compile", failure_code="compilerError",
            exit_code=1, log=log, compiler_diagnostic=("ownedRdpdr", None, "other"),
        )
    assert not (tmp_path / "failure.json").exists()
