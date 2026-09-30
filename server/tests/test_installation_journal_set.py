"""First-install-only authority for the host installation journal set."""

import importlib.util
import json
import os
from pathlib import Path
import shutil

import pytest

from larenor_server.plugins.resource_journal import ResourceJournal


ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "deploy/larenor-server/host_workers/installation_journals.py"
SPEC = importlib.util.spec_from_file_location("installation_journals", SOURCE)
journals = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(journals)


def _policy(root):
    return {
        "version": 1,
        "platform": "linux/amd64",
        "docker": {
            "socketPath": "/var/run/docker.sock",
            "ownerUid": 0,
            "daemonExecutable": "/usr/bin/dockerd",
        },
        "workerPolicy": {
            "schemaVersion": 1,
            "workerPolicyVersion": 3,
            "workerPolicyDigest": "d" * 64,
        },
        "bootstrap": {"imageId": "sha256:" + "9" * 64},
        "journals": {
            "resources": str(root / "resources"),
            "volumes": str(root / "volumes"),
            "containers": str(root / "containers"),
        },
    }


@pytest.fixture
def installation(tmp_path, monkeypatch):
    root = tmp_path / "installation"
    root.mkdir(mode=0o700)
    policy = tmp_path / "installation.json"
    policy.write_text(json.dumps(_policy(root)))
    policy.chmod(0o600)
    expected = {
        "resources": root / "resources",
        "volumes": root / "volumes",
        "containers": root / "containers",
    }
    monkeypatch.setattr(journals, "POLICY", policy)
    monkeypatch.setattr(journals, "STATE_ROOT", root)
    monkeypatch.setattr(journals, "EXPECTED_JOURNALS", expected)
    return root, policy, expected


def _receipt(root):
    return json.loads((root / "journal-set.json").read_text())


def _journal_bytes(path):
    return {
        str(item.relative_to(path)): item.read_bytes()
        for item in sorted(path.iterdir())
        if item.is_file()
    }


def test_initialize_publishes_one_bound_set_and_verify_never_mutates(installation):
    root, _policy_path, expected = installation

    assert journals.main(["verify"]) == 1
    assert journals.main(["initialize"]) == 0
    receipt = _receipt(root)
    assert receipt["state"] == "ready"
    assert set(receipt["journals"]) == set(expected)
    assert not (root / "journal-set.intent.json").exists()
    before = {
        name: _journal_bytes(path)
        for name, path in expected.items()
    }

    assert journals.main(["verify"]) == 0
    assert journals.main(["initialize"]) == 0
    assert _receipt(root) == receipt
    assert {
        name: _journal_bytes(path)
        for name, path in expected.items()
    } == before


def test_published_set_never_recreates_missing_history(installation):
    root, _policy_path, expected = installation
    assert journals.main(["initialize"]) == 0
    shutil.rmtree(expected["volumes"])

    assert journals.main(["verify"]) == 1
    assert journals.main(["initialize"]) == 1
    assert not expected["volumes"].exists()
    assert (root / "journal-set.json").exists()


def test_partial_set_requires_a_durable_first_install_intent(installation):
    root, _policy_path, expected = installation
    with ResourceJournal(expected["resources"], initialize=True):
        pass

    assert journals.main(["initialize"]) == 1
    assert not expected["volumes"].exists()
    assert not expected["containers"].exists()
    assert not (root / "journal-set.json").exists()


def test_durable_intent_resumes_interrupted_first_initialization(installation):
    root, _policy_path, expected = installation
    journals._write_atomic(root / "journal-set.intent.json", journals._intent_value())
    with ResourceJournal(expected["resources"], initialize=True):
        pass

    assert journals.main(["initialize"]) == 0
    assert journals.main(["verify"]) == 0
    assert all(path.is_dir() for path in expected.values())
    assert not (root / "journal-set.intent.json").exists()


def test_policy_must_bind_the_same_fixed_docker_and_journal_authority(
    installation, capsys
):
    root, policy, expected = installation
    value = _policy(root)
    value["journals"]["containers"] = str(root / "other-containers")
    policy.write_text(json.dumps(value))

    assert journals.main(["initialize"]) == 1
    assert capsys.readouterr().err.strip() == "installation_journal_set_invalid"
    assert not any(path.exists() for path in expected.values())
