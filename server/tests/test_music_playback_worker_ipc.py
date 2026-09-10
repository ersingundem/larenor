"""UID-private bounded IPC and Core handoff for playback effects."""

import json
import os
from pathlib import Path
import socket
import stat
import struct
import tempfile
import threading
import time

import pytest

from conftest import auth
from larenor_server.errors import ApiError
from larenor_server.plugins.music_target_effect_models import (
    MusicTargetEffectEnvelope, MusicTargetEffectResult,
)
from larenor_server.plugins.music_target_ipc import (
    MAX_PACKET, MusicTargetIPCError, MusicTargetWorkerClient,
    MusicTargetWorkerServer, read_packet, write_packet,
)
from test_music_target_journal import confirmed


def socket_path():
    root = "/private/tmp" if Path("/private/tmp").is_dir() else "/tmp"
    directory = tempfile.TemporaryDirectory(prefix="larenor-music-", dir=root)
    return directory, Path(directory.name) / "worker.sock"


def action(**changes):
    values = {
        "executionId": "1" * 32, "commandId": "2" * 32,
        "requestId": "3" * 32, "previewId": "4" * 32,
        "installationId": "5" * 32, "installationRevision": 6,
        "coreRevision": 7, "playerRevision": 8,
        "providerRevisions": [{
            "id": "6" * 32, "revision": 9,
            "providerDomain": "spotify"}],
        "target": {
            "id": "homepod-living", "name": "Living HomePod",
            "provider": "airplay--main", "transport": "airplay",
            "kind": "device", "homePod": True, "available": True,
            "enabled": True, "playbackState": "paused", "volumeLevel": 30,
            "muted": False, "groupMemberIds": [],
            "queueId": "homepod-living",
            "capabilities": ["play", "pause", "volume_set", "queue"],
        },
        "operation": "pause", "volumeLevel": None, "muted": None,
        "mediaUris": [],
    }
    values.update(changes)
    return MusicTargetEffectEnvelope.model_validate(values)


class Backend:
    def __init__(self):
        self.calls = []

    def execute_music_target_effect(self, effect, *, deadline, gate):
        assert time.monotonic() < deadline and gate() is True
        self.calls.append(effect)
        return MusicTargetEffectResult(
            state="succeeded", executionId=effect.executionId,
            commandId=effect.commandId, requestId=effect.requestId,
            target=effect.target)


def test_uid_private_socket_executes_one_exact_secret_free_effect():
    directory, path = socket_path()
    backend = Backend()
    server = MusicTargetWorkerServer(
        path, backend, allowed_uid=os.getuid(),
        peer_uid=lambda _connection: os.getuid(), timeout=.5)
    server.start()
    try:
        assert stat.S_IMODE(path.stat().st_mode) == 0o600
        client = MusicTargetWorkerClient(
            path, owner_uid=os.getuid(),
            peer_uid=lambda _connection: os.getuid(), timeout=.5)
        effect = action()
        result = client.execute_music_target_effect(
            effect, deadline=time.monotonic() + .4, gate=lambda: True)
        assert result.executionId == effect.executionId
        assert result.requestId == effect.requestId
        assert len(backend.calls) == 1
        wire = effect.model_dump(mode="json")
        assert not ({"url", "baseUrl", "endpoint", "token", "cookie"} & set(
            json.dumps(wire).lower().replace('"', ' ').split()))
        with pytest.raises(MusicTargetIPCError):
            client.execute_music_target_effect(
                effect, deadline=time.monotonic() + .4, gate=lambda: True)
        assert len(backend.calls) == 1
    finally:
        server.close()
        directory.cleanup()


def test_wrong_uid_cancel_deadline_and_unknown_operation_never_dispatch():
    directory, path = socket_path()
    backend = Backend()
    server = MusicTargetWorkerServer(
        path, backend, allowed_uid=os.getuid(),
        peer_uid=lambda _connection: os.getuid(), timeout=.15)
    server.start()
    try:
        denied = MusicTargetWorkerClient(
            path, owner_uid=os.getuid(),
            peer_uid=lambda _connection: os.getuid() + 1, timeout=.1)
        trusted = MusicTargetWorkerClient(
            path, owner_uid=os.getuid(),
            peer_uid=lambda _connection: os.getuid(), timeout=.1)
        for client, deadline, gate in (
            (denied, time.monotonic() + .08, lambda: True),
            (trusted, time.monotonic() + .08, lambda: False),
            (trusted, time.monotonic() - 1, lambda: True),
        ):
            with pytest.raises(MusicTargetIPCError):
                client.execute_music_target_effect(
                    action(), deadline=deadline, gate=gate)
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
            connection.connect(str(path))
            deadline = time.monotonic() + .1
            request = {
                "protocol": 1, "requestId": "a" * 32,
                "operation": "delete_everything", "effect": action().model_dump(
                    mode="json")}
            write_packet(connection, request, deadline)
            response = read_packet(connection, deadline)
            assert response == {
                "protocol": 1, "requestId": "a" * 32,
                "error": "invalid_request"}
        assert backend.calls == []
    finally:
        server.close()
        directory.cleanup()


def test_partial_and_oversize_frames_are_bounded_and_server_recovers():
    directory, path = socket_path()
    backend = Backend()
    server = MusicTargetWorkerServer(
        path, backend, allowed_uid=os.getuid(),
        peer_uid=lambda _connection: os.getuid(), timeout=.08)
    server.start()
    try:
        for payload in (b"\x00\x00", struct.pack("!I", MAX_PACKET + 1)):
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
                connection.connect(str(path))
                connection.sendall(payload)
            time.sleep(.1)
        client = MusicTargetWorkerClient(
            path, owner_uid=os.getuid(),
            peer_uid=lambda _connection: os.getuid(), timeout=.3)
        assert client.execute_music_target_effect(
            action(), deadline=time.monotonic() + .25,
            gate=lambda: True).state == "succeeded"
        assert len(backend.calls) == 1
    finally:
        server.close()
        directory.cleanup()


def _lost_response_server(path, captured):
    listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    listener.bind(str(path))
    os.chmod(path, 0o600)
    listener.listen(1)

    def run():
        with listener:
            connection, _ = listener.accept()
            with connection:
                captured.append(read_packet(
                    connection, time.monotonic() + .5))

    thread = threading.Thread(target=run, daemon=True)
    thread.start()
    return thread


def test_core_lost_response_is_unknown_and_same_request_never_replays(server):
    app, _client, _settings, _clock = server
    pair, _setup, _readiness, worker, _playback, _confirmation, command = confirmed(
        server, "a")
    actor = app.state.core.auth.authenticate(pair["accessToken"])
    directory, path = socket_path()
    captured = []
    thread = _lost_response_server(path, captured)
    manager = app.state.core.music_target_authority
    manager.effect_backend = MusicTargetWorkerClient(
        path, owner_uid=os.getuid(),
        peer_uid=lambda _connection: os.getuid(), timeout=.4)
    manager.effect_available = True
    try:
        with pytest.raises(ApiError) as lost:
            manager.execute_confirmed(
                actor, command["id"], 1, "f" * 32, gate=lambda: True)
        assert lost.value.code == "music_playback_worker_unavailable"
        thread.join(.5)
        assert len(captured) == 1
        envelope = captured[0]["effect"]
        assert envelope["requestId"] == "f" * 32
        assert envelope["target"]["queueId"] == "homepod-living"
        assert envelope["providerRevisions"][0]["providerDomain"] == "spotify"
        serialized = json.dumps(captured)
        assert all(word not in serialized.lower() for word in (
            "private-mass-token", "token", "cookie", "baseurl", "endpoint"))

        repeated = manager.execute_confirmed(
            actor, command["id"], 1, "f" * 32, gate=lambda: True)
        assert repeated["state"] == "unknown"
        assert repeated["code"] == "effect_unknown"
        with pytest.raises(ApiError):
            manager.execute_confirmed(
                actor, command["id"], 1, "e" * 32, gate=lambda: True)
        with manager.db.connection() as connection:
            assert connection.execute(
                "SELECT COUNT(*) FROM music_target_effect_attempts WHERE command_id=?",
                (command["id"],)).fetchone()[0] == 1
        assert worker.calls == []
    finally:
        directory.cleanup()
