import os
from pathlib import Path
import shutil

import pytest
from fastapi.testclient import TestClient

from conftest import Clock, auth, ready
from larenor_server.app import create_app
from larenor_server.config import Settings
from support.f41_frigate_fixture import FrigateFixture, provision


def _required_media_binary(name: str, environment: str) -> Path:
    configured = os.environ.get(environment)
    discovered = shutil.which(name)
    candidate = configured or discovered
    if candidate is None:
        pytest.fail(f"required real {name} runtime is unavailable")
    path = Path(candidate)
    if not path.is_absolute():
        pytest.fail(f"required real {name} runtime path is not absolute")
    try:
        resolved = path.resolve(strict=True)
    except (OSError, RuntimeError):
        pytest.fail(f"required real {name} runtime path is invalid")
    if not resolved.is_file() or not os.access(resolved, os.X_OK):
        pytest.fail(f"required real {name} runtime is not executable")
    if configured is not None:
        if discovered is None:
            pytest.fail(f"required real {name} runtime is absent from PATH")
        try:
            discovered_path = Path(discovered).resolve(strict=True)
        except (OSError, RuntimeError):
            pytest.fail(f"required real {name} PATH runtime is invalid")
        if discovered_path != resolved:
            pytest.fail(f"configured and PATH {name} runtimes differ")
    return resolved


@pytest.fixture(scope="module")
def media_binaries() -> tuple[Path, Path]:
    ffmpeg = _required_media_binary("ffmpeg", "LARENOR_TEST_FFMPEG")
    ffprobe = _required_media_binary("ffprobe", "LARENOR_TEST_FFPROBE")
    if ffmpeg == ffprobe:
        pytest.fail("required real ffmpeg and ffprobe runtimes are not distinct")
    return ffmpeg, ffprobe


@pytest.fixture
def frigate():
    value = FrigateFixture()
    yield value
    value.close()
    assert value.errors == []


def _scope(authority):
    return {
        "schemaVersion": 1,
        "coreRevision": authority["coreRevision"],
        "homeRevision": authority["homeRevision"],
        "accountRevision": authority["accountRevision"],
        "membersRevision": authority["membersRevision"],
        "cameraRevision": authority["cameraRevision"],
        "eventRevision": authority["eventRevision"],
        "sessionRevision": authority["sessionRevision"],
        "expectedShareRevision": authority["shareRevision"],
    }


def test_private_event_redaction_binaries_must_be_paired(tmp_path):
    with pytest.raises(ValueError, match="invalid_private_event_configuration"):
        Settings(
            tmp_path / "data",
            tmp_path / "secrets/vault.key",
            private_event_ffmpeg=Path("/usr/bin/ffmpeg"),
        )


def test_normal_core_real_frigate_redaction_encryption_restart_revoke(
    tmp_path, frigate, media_binaries
):
    root = tmp_path.resolve()
    clock = Clock()
    ffmpeg, ffprobe = media_binaries
    settings = Settings(
        root / "data",
        root / "secrets/vault.key",
        clock=clock,
        login_ip_limit=100,
        login_account_limit=100,
        login_global_limit=100,
        private_event_ffmpeg=ffmpeg,
        private_event_ffprobe=ffprobe,
    )
    with TestClient(create_app(settings)) as client:
        app = client.app
        actor = ready((app, client, settings, clock))
        camera_root, _setup, _body, cameras, _services = provision(
            client, app.state.core, actor, frigate
        )
        search = client.post(
            camera_root + "/search",
            headers=auth(actor),
            json={
                "schemaVersion": 1,
                "query": "red parcel",
                "expectedIndexRevision": 1,
                "startMs": 1788609500000,
                "endMs": 1788609700000,
                "cameraIds": cameras,
                "pageSize": 1,
                "cursor": None,
            },
        )
        assert search.status_code == 200, search.text
        evidence = search.json()["results"][0]["evidence"]
        context = app.state.core.context
        policy_root = (
            f"/api/v1/admin/private-event-sharing/{context.coreId}/{context.homeId}/policy"
        )
        policy = client.put(
            policy_root,
            headers=auth(actor),
            json={
                "schemaVersion": 1,
                "expectedRevision": 0,
                "active": True,
                "grantorIds": [actor["user"]["id"]],
                "recipientIds": [actor["user"]["id"]],
                "purposes": ["Door incident"],
                "accessModes": ["time_bound"],
                "maxTtlSeconds": 600,
                "requiredMasks": ["face", "license_plate"],
                "requiredMetadata": ["gps", "camera_name"],
                "redactionMode": "full_frame_blur",
            },
        )
        assert policy.status_code == 200, policy.text
        assert policy.json()["capability"] == {
            "schemaVersion": 1,
            "mode": "full_frame_blur",
            "targetedRecognition": False,
            "coversEntireFrame": True,
        }
        event_root = (
            f"/api/v1/private-event-sharing/{context.coreId}/{context.homeId}/"
            f"{evidence['cameraId']}/{evidence['eventId']}"
        )
        authority_response = client.get(event_root + "/context", headers=auth(actor))
        assert authority_response.status_code == 200, authority_response.text
        authority = authority_response.json()
        assert authority["canShare"] is True
        consent = client.post(
            event_root + "/consents",
            headers=auth(actor),
            json={
                **_scope(authority),
                "expectedPolicyRevision": 1,
                "recipientId": actor["user"]["id"],
                "purpose": "Door incident",
                "expiresAt": clock.now + 300,
                "accessMode": "time_bound",
                "masks": ["face", "license_plate"],
                "removedMetadata": ["gps", "camera_name"],
            },
        )
        assert consent.status_code == 201, consent.text
        preview = client.post(
            event_root + "/preview",
            headers=auth(actor),
            json={
                **_scope(authority),
                "masks": ["face", "license_plate"],
                "removedMetadata": ["gps", "camera_name"],
            },
        )
        assert preview.status_code == 200, preview.text
        transformation = preview.json()["transformation"]
        assert transformation["sourceDigest"] != transformation["outputDigest"]
        assert transformation["masks"] == ["face", "license_plate"]
        created = client.post(
            event_root + "/shares",
            headers=auth(actor),
            json={
                **_scope(authority),
                "commandId": "d" * 32,
                "consentId": consent.json()["consentId"],
                "consentRevision": 1,
                "recipientId": actor["user"]["id"],
                "purpose": "Door incident",
                "expiresAt": clock.now + 300,
                "accessMode": "time_bound",
                "transformation": transformation,
            },
        )
        assert created.status_code == 201, created.text
        access_token = created.json()["accessToken"]
        share_id = created.json()["share"]["id"]
        with app.state.core.db.connection() as connection:
            row = connection.execute(
                "SELECT ciphertext FROM private_event_share_artifacts WHERE id=?",
                (transformation["outputArtifactId"],),
            ).fetchone()
        assert row is not None
        assert b"ftyp" not in row["ciphertext"]
        assert frigate.token.encode() not in row["ciphertext"]

        frigate.events.clear()

    with TestClient(create_app(settings)) as restarted:
        current = restarted.get(event_root + "/context", headers=auth(actor))
        assert current.status_code == 200, current.text
        assert current.json()["canShare"] is True
        unavailable_preview = restarted.post(
            event_root + "/preview",
            headers=auth(actor),
            json={
                **_scope(current.json()),
                "masks": ["face", "license_plate"],
                "removedMetadata": ["gps", "camera_name"],
            },
        )
        assert unavailable_preview.status_code in (409, 503)
        downloaded = restarted.post(
            event_root + "/download",
            headers=auth(actor),
            json={
                "schemaVersion": 1,
                "accessId": "e" * 32,
                "accessToken": access_token,
            },
        )
        assert downloaded.status_code == 200, downloaded.text
        assert downloaded.content[4:8] == b"ftyp"
        after_download = restarted.get(event_root + "/context", headers=auth(actor)).json()
        revoked = restarted.post(
            event_root + "/revoke",
            headers=auth(actor),
            json={
                **_scope(after_download),
                "commandId": "f" * 32,
                "shareId": share_id,
            },
        )
        assert revoked.status_code == 200, revoked.text
        denied = restarted.post(
            event_root + "/download",
            headers=auth(actor),
            json={
                "schemaVersion": 1,
                "accessId": "9" * 32,
                "accessToken": access_token,
            },
        )
        assert denied.status_code == 404
