import json
from pathlib import Path
import subprocess
import sys
import time

import pytest

from conftest import auth, ready
from larenor_server.errors import ApiError, StartupError
from larenor_server.private_event_sharing.provider import (
    CorePrivateEventSharingProvider,
    FfmpegFullFrameRedactor,
    _EncryptedProviderStore,
)
from larenor_server.private_event_sharing.provider_schema import (
    migrate_private_event_share_provider,
)
from larenor_server.private_event_sharing.schema import migrate_private_event_sharing
from larenor_server.private_event_sharing.service import EventShareAuthority


CAMERA = "a" * 32
EVENT = "b" * 32
RECIPIENT = "c" * 32


class CameraRuntime:
    def __init__(self, source, core_id, home_id):
        self.source = source
        self.core_id, self.home_id = core_id, home_id
        self.available = True
        self.reads = 0

    def _binding(self):
        return {
            "schemaVersion": 1,
            "evidence": {
                "schemaVersion": 1,
                "kind": "camera_evidence",
                "coreId": self.core_id,
                "homeId": self.home_id,
                "cameraId": CAMERA,
                "clipId": "d" * 32,
                "eventId": EVENT,
                "captureRevision": 41,
                "indexRevision": 7,
                "capturedAtMs": 1_788_609_600_000,
            },
            "seal": "sealed-private-provider-fixture" * 3,
            "cameraRevision": 43,
            "sourceRevision": 7,
            "expiresAtMs": 1_788_609_600_000 + 604_800_000,
        }

    def private_event_binding(self, *_args, **_kwargs):
        return self._binding()

    def authorize_private_event_binding(self, *_args, **_kwargs):
        if not self.available:
            raise ApiError("revision_conflict", 409)
        return self._binding()

    def read_private_event_clip(self, *_args, **_kwargs):
        if not self.available:
            raise ApiError("revision_conflict", 409)
        self.reads += 1
        return self.source


def _migrate(core):
    with core.db.transaction() as connection:
        migrate_private_event_share_provider(connection)


def _raw_video(path):
    return subprocess.check_output(
        [
            "/opt/homebrew/bin/ffmpeg",
            "-v",
            "error",
            "-nostdin",
            "-i",
            str(path),
            "-f",
            "rawvideo",
            "-pix_fmt",
            "gray",
            "-",
        ]
    )


def test_encrypted_policy_artifact_and_real_full_frame_redaction(
    server, tmp_path, monkeypatch
):
    app, _client, settings, clock = server
    _migrate(app.state.core)
    key = settings.key_file.read_bytes()
    store = _EncryptedProviderStore(app.state.core.db, key, clock)
    administrator = app.state.core.auth.authenticate(ready(server)["accessToken"])
    policy = store.put_policy(
        0,
        administrator.id,
        {
            "active": True,
            "grantor_ids": (administrator.id,),
            "recipient_ids": (administrator.id,),
            "purposes": ("Door incident",),
            "access_modes": ("one_time",),
            "max_ttl_seconds": 600,
            "required_masks": ("face", "license_plate"),
            "required_metadata": ("gps", "camera_name"),
            "redaction_mode": "full_frame_blur",
        },
    )
    assert store.policy() == policy
    redactor = FfmpegFullFrameRedactor(
        Path("/opt/homebrew/bin/ffmpeg"),
        Path("/opt/homebrew/bin/ffprobe"),
        tmp_path / "redaction-work",
        store,
        clock,
    )
    commands = []
    original_run = redactor._run

    def recording_run(command, timeout, guard=lambda: None):
        commands.append(tuple(command))
        return original_run(command, timeout, guard)

    monkeypatch.setattr(redactor, "_run", recording_run)
    scope = EventShareAuthority(
        "1" * 32, "2" * 32, administrator.id, administrator.family_id,
        1, 1, 1, 1, CAMERA, 43, EVENT, 41, 1, 1,
        (administrator.id,), True,
    )
    source_path = Path(__file__).parent / "support/assets/f41_clip.mp4"
    source = source_path.read_bytes()
    artifact = redactor(
        scope,
        source,
        ("face", "license_plate"),
        ("gps", "camera_name"),
        64 * 1024 * 1024,
    )
    assert store.artifact(artifact.artifact_id, 64 * 1024 * 1024) == artifact.content
    output = tmp_path / "redacted.mp4"
    output.write_bytes(artifact.content)
    original_frames, redacted_frames = _raw_video(source_path), _raw_video(output)
    assert len(original_frames) == len(redacted_frames) == 160 * 90 * 10
    size = 160 * 90
    for offset in range(0, len(original_frames), size):
        before = original_frames[offset : offset + size]
        after = redacted_frames[offset : offset + size]
        assert sum(a != b for a, b in zip(before, after)) / size > 0.90
    probe = json.loads(
        subprocess.check_output(
            [
                "/opt/homebrew/bin/ffprobe", "-v", "error", "-show_streams",
                "-show_format", "-show_chapters", "-of", "json", str(output),
            ]
        )
    )
    assert probe.get("chapters", []) == []
    assert {stream["codec_type"] for stream in probe["streams"]} == {"video"}
    assert artifact.masks == ("face", "license_plate")
    assert artifact.removed_metadata == ("camera_name", "gps")
    assert commands
    assert all(
        "-protocol_whitelist" in command
        and command[command.index("-protocol_whitelist") + 1] == "file,pipe"
        for command in commands
    )

    original_probe = redactor._probe

    def mismatched_output_timeline(path, *, count_frames, guard=lambda: None):
        value = original_probe(path, count_frames=count_frames, guard=guard)
        if path.name == "redacted.mp4" and count_frames:
            value["format"]["duration"] = "3.000000"
        return value

    monkeypatch.setattr(redactor, "_probe", mismatched_output_timeline)
    with pytest.raises(ApiError, match="transformation_unverified"):
        redactor(
            scope,
            source,
            ("face", "license_plate"),
            ("gps", "camera_name"),
            64 * 1024 * 1024,
        )

    def forbidden_output_metadata(path, *, count_frames, guard=lambda: None):
        value = original_probe(path, count_frames=count_frames, guard=guard)
        if path.name == "redacted.mp4" and count_frames:
            value["format"].setdefault("tags", {})[
                "com.apple.quicktime.location.ISO6709"
            ] = "+41.0+029.0/"
        return value

    monkeypatch.setattr(redactor, "_probe", forbidden_output_metadata)
    with pytest.raises(ApiError, match="transformation_unverified"):
        redactor(
            scope,
            source,
            ("face", "license_plate"),
            ("gps", "camera_name"),
            64 * 1024 * 1024,
        )

    probes = []

    def oversized_header(_path, *, count_frames, guard=lambda: None):
        guard()
        probes.append(count_frames)
        return {
            "streams": [{
                "codec_type": "video", "width": 4096, "height": 4096,
                "avg_frame_rate": "30/1",
            }],
            "format": {"duration": "1.0"},
            "chapters": [],
        }

    monkeypatch.setattr(redactor, "_probe", oversized_header)
    with pytest.raises(ApiError, match="transformation_unverified"):
        redactor(
            scope,
            source,
            ("face", "license_plate"),
            ("gps", "camera_name"),
            64 * 1024 * 1024,
        )
    assert probes == [False]

    with app.state.core.db.transaction() as connection:
        connection.execute(
            "UPDATE private_event_share_artifacts SET ciphertext=? WHERE id=?",
            (b"tampered", artifact.artifact_id),
        )
    with pytest.raises(ApiError, match="share_unavailable"):
        store.artifact(artifact.artifact_id, 64 * 1024 * 1024)
    clock.now += 700
    with pytest.raises(
        StartupError, match="private_event_share_provider_storage_invalid"
    ):
        store.validate_storage()


def test_redaction_process_output_is_bounded_and_child_is_terminated():
    with pytest.raises(ApiError, match="transformation_unverified"):
        FfmpegFullFrameRedactor._run(
            [
                sys.executable,
                "-c",
                "import os; os.write(1, b'x' * (1024 * 1024 + 1))",
            ],
            5,
        )

    started = time.monotonic()

    def revoked():
        if time.monotonic() - started >= 0.2:
            raise ApiError("authority_changed", 409)

    with pytest.raises(ApiError, match="authority_changed"):
        FfmpegFullFrameRedactor._run(
            [
                sys.executable,
                "-c",
                "import os,time; os.close(1); os.close(2); time.sleep(30)",
            ],
            5,
            revoked,
        )
    assert time.monotonic() - started < 2


def test_authority_consent_and_source_deletion_separate_new_transform_from_revoke(server):
    app, _client, settings, clock = server
    actor_tokens = ready(server)
    actor = app.state.core.auth.authenticate(actor_tokens["accessToken"])
    _migrate(app.state.core)
    source = (Path(__file__).parent / "support/assets/f41_clip.mp4").read_bytes()
    runtime = CameraRuntime(
        source, app.state.core.context.coreId, app.state.core.context.homeId
    )
    provider = CorePrivateEventSharingProvider(
        app.state.core,
        app.state.core.db,
        settings.key_file.read_bytes(),
        app.state.core.context,
        app.state.core.private_event_share_store,
        lambda: runtime,
        clock=clock,
    )
    provider.configure_policy(
        actor,
        app.state.core.context.coreId,
        app.state.core.context.homeId,
        {
            "expected_revision": 0,
            "active": True,
            "grantor_ids": [actor.id],
            "recipient_ids": [actor.id],
            "purposes": ["Door incident"],
            "access_modes": ["one_time"],
            "max_ttl_seconds": 600,
            "required_masks": ["face", "license_plate"],
            "required_metadata": ["gps", "camera_name"],
            "redaction_mode": "full_frame_blur",
        },
    )
    authority = provider.authority(actor, CAMERA, EVENT)
    assert authority.can_share
    consent = provider.accept_consent(
        actor,
        CAMERA,
        EVENT,
        {
            "authority": {
                "coreRevision": authority.core_revision,
                "homeRevision": authority.home_revision,
                "accountRevision": authority.account_revision,
                "membersRevision": authority.members_revision,
                "cameraRevision": authority.camera_revision,
                "eventRevision": authority.event_revision,
                "sessionRevision": authority.session_revision,
                "expectedShareRevision": authority.share_revision,
            },
            "expected_policy_revision": 1,
            "recipient_id": actor.id,
            "purpose": "Door incident",
            "expires_at": clock.now + 300,
            "access_mode": "one_time",
            "masks": ["face", "license_plate"],
            "removed_metadata": ["gps", "camera_name"],
        },
    )
    resolved = provider.consent_resolver(actor, consent["consentId"])
    assert resolved.recipient_id == actor.id
    assert provider.event_reader(actor, authority, 64 * 1024 * 1024) == source
    assert runtime.reads == 1

    runtime.available = False
    historical = provider.authority(actor, CAMERA, EVENT)
    assert not historical.can_share
    assert historical.camera_revision == authority.camera_revision
    assert historical.event_revision == authority.event_revision
    with pytest.raises(ApiError, match="authority_changed"):
        provider.event_reader(actor, authority, 64 * 1024 * 1024)
    provider._redaction_guard(
        authority,
        ("face", "license_plate"),
        ("gps", "camera_name"),
    )
    with app.state.core.db.transaction() as connection:
        connection.execute(
            "UPDATE session_families SET revoked_at=? WHERE id=?",
            (clock.now, actor.family_id),
        )
    with pytest.raises(ApiError, match="authority_changed"):
        provider._redaction_guard(
            authority,
            ("face", "license_plate"),
            ("gps", "camera_name"),
        )


def test_provider_schema_reopen_and_tampered_policy_fail_closed(server):
    app, _client, settings, clock = server
    actor = app.state.core.auth.authenticate(ready(server)["accessToken"])
    _migrate(app.state.core)
    _migrate(app.state.core)
    store = _EncryptedProviderStore(app.state.core.db, settings.key_file.read_bytes(), clock)
    store.put_policy(
        0,
        actor.id,
        {
            "active": True,
            "grantor_ids": (actor.id,),
            "recipient_ids": (actor.id,),
            "purposes": ("Door incident",),
            "access_modes": ("time_bound",),
            "max_ttl_seconds": 600,
            "required_masks": ("face",),
            "required_metadata": ("gps",),
            "redaction_mode": "full_frame_blur",
        },
    )
    store.validate_storage()
    with app.state.core.db.transaction() as connection:
        connection.execute(
            "UPDATE private_event_share_policy SET record_hash=? WHERE singleton=1",
            ("0" * 64,),
        )
    with pytest.raises(StartupError, match="private_event_share_provider_storage_invalid"):
        store.validate_storage()


def test_paired_schema_accepts_known_tables_but_rejects_unknown_namespace(server):
    app, _client, _settings, _clock = server
    _migrate(app.state.core)
    with app.state.core.db.transaction() as connection:
        migrate_private_event_sharing(connection)
        migrate_private_event_share_provider(connection)
        connection.execute(
            "CREATE TABLE private_event_share_unknown_tamper (value TEXT)"
        )
    with app.state.core.db.transaction() as connection:
        with pytest.raises(StartupError, match="private_event_share_storage_invalid"):
            migrate_private_event_sharing(connection)
