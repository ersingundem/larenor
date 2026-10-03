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


def archive_source_index(probe, tmp_path: Path, files: dict[str, bytes]):
    source = tmp_path / "source"
    source.mkdir(mode=0o700)
    for relative, raw in files.items():
        path = source / relative
        path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        path.write_bytes(raw)
        path.chmod(0o600)
    return source, probe._build_archive_source_index(source)


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
    source, source_index = archive_source_index(
        probe,
        tmp_path,
        {"libfreerdp/core/transport.c": b"one\ntwo\nthree\nfour\nfive\n"},
    )
    command = tmp_path / "compiler"
    command.write_text(
        "#!/bin/sh\n"
        f"printf '%s\\n' '{source}/libfreerdp/core/transport.c:4:10: error: "
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
            compiler_source=source, compiler_index=source_index,
        )
    value = json.loads(receipt.read_text())
    assert set(value) == probe.BUILD_FAILURE_RECEIPT_KEYS
    assert value["runnerSourceRevision"] == revision
    assert value["phase"] == "compile"
    assert value["schemaVersion"] == 3
    assert value["failureCode"] == "compilerError"
    assert value["compilerSource"] == "archiveSource"
    assert value["compilerLine"] == 4
    assert value["compilerErrorClass"] == "missingMember"
    assert value["compilerUnit"] == "libfreerdp/core/transport.c"
    assert value["compilerUnitSha256"] == source_index[
        "libfreerdp/core/transport.c"
    ][0]
    assert value["exitCode"] == 7
    assert value["featureAccepted"] is False
    encoded = receipt.read_text()
    assert str(source) not in encoded
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


def test_archive_index_refreshes_only_an_exact_manifest_bound_source(
    tmp_path: Path,
) -> None:
    probe, _ = modules()
    source, source_index = archive_source_index(
        probe,
        tmp_path,
        {
            "server/shadow/shadow_channels.c": b"original\n",
            "libfreerdp/core/transport.c": b"unchanged\n",
        },
    )
    target = source / "server/shadow/shadow_channels.c"
    target.write_bytes(b"patched\nsecond\n")
    patched_digest = probe.hashlib.sha256(target.read_bytes()).hexdigest()
    refreshed = probe._refresh_manifest_source_index(
        source,
        source_index,
        {"server/shadow/shadow_channels.c": patched_digest},
    )
    assert refreshed["server/shadow/shadow_channels.c"] == (patched_digest, 2)
    assert refreshed["libfreerdp/core/transport.c"] == source_index[
        "libfreerdp/core/transport.c"
    ]
    with pytest.raises(probe.ProbeError):
        probe._refresh_manifest_source_index(
            source,
            source_index,
            {"server/shadow/shadow_channels.c": "f" * 64},
        )


def test_archive_index_ignores_empty_source_units_that_cannot_name_a_line(
    tmp_path: Path,
) -> None:
    probe, _ = modules()
    source, source_index = archive_source_index(
        probe,
        tmp_path,
        {
            "libfreerdp/core/empty.c": b"",
            "libfreerdp/core/transport.c": b"one\ntwo\n",
        },
    )
    assert set(source_index) == {"libfreerdp/core/transport.c"}
    assert probe._compiler_diagnostic(
        b"libfreerdp/core/empty.c:1:1: error: private",
        source=source,
        source_index=source_index,
    ) == (None, None, None, None, None)


def test_compiler_diagnostic_identifies_any_hash_bound_archive_source(tmp_path: Path) -> None:
    probe, _ = modules()
    source, source_index = archive_source_index(
        probe,
        tmp_path,
        {
            "libfreerdp/core/transport.c": b"one\ntwo\nthree\n",
            "server/shadow/shadow_channels.c": b"one\ntwo\nthree\n",
        },
    )
    generic = (
        f"{source}/libfreerdp/core/transport.c:2:10: error: "
        "struct private has no member named secret"
    ).encode()
    assert probe._compiler_diagnostic(
        generic, source=source, source_index=source_index,
    ) == (
        "archiveSource", 2, "missingMember", "libfreerdp/core/transport.c",
        source_index["libfreerdp/core/transport.c"][0],
    )
    special = (
        b"server/shadow/shadow_channels.c:3:7: error: call to undeclared "
        b"function 'private_secret'"
    )
    assert probe._compiler_diagnostic(
        special, source=source, source_index=source_index,
    ) == (
        "shadowChannels", 3, "undeclaredIdentifier",
        "server/shadow/shadow_channels.c",
        source_index["server/shadow/shadow_channels.c"][0],
    )


def test_compiler_diagnostic_rejects_external_unknown_mutated_and_out_of_range(
    tmp_path: Path,
) -> None:
    probe, _ = modules()
    source, source_index = archive_source_index(
        probe,
        tmp_path,
        {"server/shadow/shadow_channels.c": b"one\ntwo\nthree\n"},
    )
    none = (None, None, None, None, None)
    for raw in (
        b"/external/server/shadow/shadow_channels.c:2:3: error: private",
        b"server/shadow/unknown.c:2:3: error: private",
        b"server/shadow/shadow_channels.c:4:3: error: private",
        b"../server/shadow/shadow_channels.c:2:3: error: private",
        b"server/shadow/shadow_channels.c:2:3: error:",
    ):
        assert probe._compiler_diagnostic(
            raw, source=source, source_index=source_index,
        ) == none
    (source / "server/shadow/shadow_channels.c").write_bytes(b"changed\n")
    assert probe._compiler_diagnostic(
        b"server/shadow/shadow_channels.c:1:3: error: private",
        source=source,
        source_index=source_index,
    ) == none


def test_compiler_diagnostic_rejects_overlong_truncated_and_nonascii_paths(
    tmp_path: Path,
) -> None:
    probe, _ = modules()
    source, source_index = archive_source_index(
        probe, tmp_path, {"libfreerdp/core/transport.c": b"one\n"},
    )
    none = (None, None, None, None, None)
    records = (
        b"libfreerdp/core/transport.c:1:2: error: " + b"x" * 513,
        b"libfreerdp/core/transport.c:1:2: error:",
        b"libfreerdp/core/trans\xffport.c:1:2: error: private",
        b"/" + b"a" * 1025 + b":1:2: error: private",
    )
    for raw in records:
        assert probe._compiler_diagnostic(
            raw, source=source, source_index=source_index,
        ) == none
    assert probe._compiler_diagnostic(
        b"undefined reference to `private_secret'",
        source=source,
        source_index=source_index,
    ) == (None, None, "linkUndefined", None, None)


def test_compiler_diagnostic_prefers_exact_unit_when_parallel_log_also_links(
    tmp_path: Path,
) -> None:
    probe, _ = modules()
    source, source_index = archive_source_index(
        probe, tmp_path, {"libfreerdp/core/transport.c": b"one\ntwo\n"},
    )
    raw = (
        b"undefined reference to `other_target'\n"
        b"libfreerdp/core/transport.c:2:4: error: expected private expression\n"
    )
    assert probe._compiler_diagnostic(
        raw, source=source, source_index=source_index,
    ) == (
        "archiveSource", 2, "syntaxError", "libfreerdp/core/transport.c",
        source_index["libfreerdp/core/transport.c"][0],
    )


@pytest.mark.parametrize(
    "diagnostic",
    (
        ("archiveSource", 4, "other", "libfreerdp/core/transport.c", "a" * 64),
        ("archiveSource", 2, None, "libfreerdp/core/transport.c", "a" * 64),
        (None, None, "missingMember", None, None),
        ("ownedRdpdr", 2, "other", "libfreerdp/core/transport.c", "a" * 64),
        ("archiveSource", 2, "other", "../transport.c", "a" * 64),
    ),
)
def test_failure_receipt_rejects_unbound_compiler_tuple(
    tmp_path: Path,
    diagnostic: tuple[
        str | None, int | None, str | None, str | None, str | None,
    ],
) -> None:
    probe, _ = modules()
    _, source_index = archive_source_index(
        probe, tmp_path, {"libfreerdp/core/transport.c": b"one\ntwo\nthree\n"},
    )
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
            compiler_index=source_index,
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


def test_truncated_compiler_message_does_not_publish_a_tuple(tmp_path: Path):
    probe, _ = modules()
    source, source_index = archive_source_index(
        probe, tmp_path, {"libfreerdp/core/transport.c": b"one\n"},
    )
    raw = b"libfreerdp/core/transport.c:1:2: error: " + b"x" * 513 + b"\n"
    assert probe._compiler_diagnostic(
        raw, source=source, source_index=source_index,
    ) == (None, None, None, None, None)


def test_missing_line_in_bound_source_tuple_fails_closed(tmp_path):
    probe, _ = modules()
    _, source_index = archive_source_index(
        probe, tmp_path, {"server/shadow/shadow_owned_rdpdr.c": b"one\ntwo\n"},
    )
    log = tmp_path / "compile.log"
    log.write_bytes(b"private input")
    with pytest.raises(probe.ProbeError):
        probe._write_build_failure(
            tmp_path / "failure.json", phase="compile", failure_code="compilerError",
            exit_code=1,
            log=log,
            compiler_diagnostic=(
                "ownedRdpdr", None, "other", "server/shadow/shadow_owned_rdpdr.c",
                source_index["server/shadow/shadow_owned_rdpdr.c"][0],
            ),
            compiler_index=source_index,
        )
    assert not (tmp_path / "failure.json").exists()
