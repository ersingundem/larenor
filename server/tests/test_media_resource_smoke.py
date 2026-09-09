"""Native image/network resource acceptance without container operations."""

from collections import deque
from types import SimpleNamespace

import pytest


def _source(platform="linux/amd64"):
    from tool.jellyfin_storage_smoke import fixture_source
    return fixture_source(platform)


class ImageEngine:
    def __init__(self):
        self.ready = False
        self.calls = []

    def inspect(self, binding, *, cancelled):
        from larenor_server.plugins.image_resources import ImageObservation
        self.calls.append("inspect")
        return ImageObservation(binding.config_digest, b"{}") if self.ready else None

    def pull(self, binding, *, cancelled):
        self.calls.append("pull")
        self.ready = True


class NetworkReader:
    def __init__(self, network_id="1" * 64):
        self.network_id = network_id
        self.created = False
        self.calls = []

    def list(self, binding, intent, *, cancelled):
        from larenor_server.plugins.network_resources import NetworkListObservation
        self.calls.append("list")
        return NetworkListObservation("candidate", self.network_id) if self.created else NetworkListObservation("missing")

    def inspect(self, binding, intent, network_id, *, cancelled):
        from larenor_server.plugins.resource_journal import NetworkIdentity
        self.calls.append("inspect")
        assert network_id == self.network_id
        return NetworkIdentity(network_id)


class NetworkCreator:
    def __init__(self, reader):
        self.reader = reader
        self.calls = 0

    def create(self, binding, intent, *, before_dispatch, cancelled):
        from larenor_server.plugins.network_effects import NetworkCreateAcknowledgement
        self.calls += 1
        assert before_dispatch() is True
        self.reader.created = True
        return NetworkCreateAcknowledgement(self.reader.network_id)


def test_resource_characterization_pulls_once_creates_once_and_reopens_journal(tmp_path):
    from tool.media_resource_smoke import characterize_resources
    source = _source()
    images, reader = ImageEngine(), NetworkReader()
    result = characterize_resources(tmp_path, source, images, reader, NetworkCreator(reader))
    assert result == {
        "imageState": "ready", "networkState": "ready", "journalRestartCount": 1,
        "networkIdentitySha256": "3138bb9bc78df27c473ecfd1410f7bd45ebac1f59cf3ff9cfe4db77aab7aedd3",
    }
    assert images.calls == ["inspect", "pull", "inspect", "inspect"]
    assert reader.calls == ["list", "list", "inspect", "list", "inspect"]


def test_resource_characterization_rejects_non_ready_final_state(tmp_path):
    from tool.media_resource_smoke import ResourceAcceptanceError, characterize_resources
    source = _source()
    images, reader = ImageEngine(), NetworkReader()
    reader.inspect = lambda *args, **kwargs: object()
    with pytest.raises(ResourceAcceptanceError, match="^resource_identity_unverified$"):
        characterize_resources(tmp_path, source, images, reader, NetworkCreator(reader))


def test_resource_source_contains_exactly_image_and_control_network_targets():
    from tool.media_resource_smoke import select_resources
    selected = select_resources(_source("linux/arm64"))
    assert selected.image.kind == "ensure_image"
    assert selected.network.kind == "prepare_control_network"
    assert selected.image.image.platform == "linux/arm64"
    assert len({selected.image.resourceId, selected.network.resourceId}) == 2


def test_public_receipt_contains_no_dynamic_resource_identifiers(tmp_path):
    from tool.media_resource_smoke import build_receipt, characterize_resources
    source = _source()
    images, reader = ImageEngine(), NetworkReader()
    observed = characterize_resources(tmp_path, source, images, reader, NetworkCreator(reader))
    receipt = build_receipt(source, "a" * 40, "linux/amd64", observed,
                            {"tool/media_resource_smoke.py": "b" * 64})
    text = repr(receipt)
    assert reader.network_id not in text
    assert source.stack.preparationId not in text
    assert receipt["installAvailable"] is False
    assert receipt["resourceKinds"] == ["ensure_image", "prepare_control_network"]


@pytest.mark.parametrize("raw", [
    b"/usr/bin/dockerd\0--data-root=/tmp/wrong\0",
    b"/usr/bin/dockerd\0--data-root=/tmp/expected",
    b"dockerd\0--data-root=/tmp/expected\0",
    b"/usr/bin/dockerd\0--data-root=/tmp/expected\0--extra\0",
], ids=("wrong-root", "missing-terminator", "changed-executable", "extra-argument"))
def test_owned_daemon_command_identity_rejects_any_argument_change(raw):
    from tool.media_resource_smoke import ResourceAcceptanceError, _daemon_command_identity
    with pytest.raises(ResourceAcceptanceError, match="^resource_daemon_unverified$"):
        _daemon_command_identity(raw,
                                 ["/usr/bin/dockerd", "--data-root=/tmp/expected"])


def test_owned_daemon_command_identity_accepts_only_exact_argv():
    from tool.media_resource_smoke import _daemon_command_identity
    assert _daemon_command_identity(
        b"/usr/bin/dockerd\0--data-root=/tmp/expected\0",
        ["/usr/bin/dockerd", "--data-root=/tmp/expected"]) is None


def test_resource_daemon_exposes_no_docker_cli_surface():
    from tool.media_resource_smoke import ResourceAcceptanceError, ResourceEphemeralDaemon
    daemon = ResourceEphemeralDaemon()
    with pytest.raises(ResourceAcceptanceError, match="^resource_cli_forbidden$"):
        daemon.docker(["info"])
