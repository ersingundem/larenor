import json
from pathlib import Path

import pytest

from larenor_server.auth import Principal
from larenor_server.database import Database
from larenor_server.errors import ApiError, StartupError
from larenor_server.private_event_sharing.schema import migrate_private_event_sharing
from larenor_server.private_event_sharing.service import (
    EventShareAuthority,
    EventShareConsent,
    PrivateEventShareStore,
    transformation_proof,
)


ENCRYPTION_KEY = bytes.fromhex("42" * 32)
AUDIT_KEY = bytes.fromhex("24" * 32)
TRANSFORM_KEY = bytes.fromhex("55" * 32)
NOW = 1_800_000_000.0


def actor(
    identifier: str, role: str = "member", session: str = "session-a"
) -> Principal:
    return Principal(identifier, identifier, role, False, session, "token")


def authority(
    account_id: str = "ada", *, share_revision: int = 7
) -> EventShareAuthority:
    return EventShareAuthority(
        core_id="core-a",
        home_id="home-a",
        account_id=account_id,
        session_id="session-a",
        core_revision=3,
        home_revision=5,
        account_revision=9,
        members_revision=11,
        camera_id="camera-door",
        camera_revision=13,
        event_id="event-99",
        event_revision=17,
        session_revision=19,
        share_revision=share_revision,
        member_ids=("ada", "baran"),
        can_share=account_id == "ada",
    )


def consent(
    *, mode: str = "one_time", expires_at: float = NOW + 600
) -> EventShareConsent:
    return EventShareConsent(
        id="consent-1",
        revision=2,
        granted_by="ada",
        recipient_id="recipient-a",
        event_id="event-99",
        purpose="door-event-review",
        accepted_at=NOW - 10,
        expires_at=expires_at,
        access_mode=mode,
        required_masks=("face", "license_plate"),
        required_metadata=("device_serial", "gps"),
    )


def evidence(*, masks=("face", "license_plate"), output_digest="b" * 64) -> dict:
    value = {
        "sourceDigest": "a" * 64,
        "outputDigest": output_digest,
        "outputArtifactId": "redacted-clip-1",
        "pipelineId": "local-redactor",
        "pipelineRevision": 4,
        "masks": list(masks),
        "removedMetadata": ["device_serial", "gps"],
    }
    value["proof"] = transformation_proof(TRANSFORM_KEY, value)
    return value


def create_bytes(
    *,
    command_id="share-1",
    share_revision=7,
    mode="one_time",
    expires_at=NOW + 600,
    evidence_value=None,
) -> bytes:
    value = {
        "action": "create",
        "commandId": command_id,
        "coreId": "core-a",
        "homeId": "home-a",
        "accountId": "ada",
        "sessionId": "session-a",
        "coreRevision": 3,
        "homeRevision": 5,
        "accountRevision": 9,
        "membersRevision": 11,
        "cameraId": "camera-door",
        "cameraRevision": 13,
        "eventId": "event-99",
        "eventRevision": 17,
        "sessionRevision": 19,
        "expectedShareRevision": share_revision,
        "consentId": "consent-1",
        "consentRevision": 2,
        "recipientId": "recipient-a",
        "purpose": "door-event-review",
        "expiresAt": expires_at,
        "accessMode": mode,
        "transformation": evidence_value or evidence(),
    }
    return json.dumps(value, sort_keys=True, separators=(",", ":")).encode()


def revoke_bytes(*, share_id: str, revision: int) -> bytes:
    return json.dumps(
        {
            "action": "revoke",
            "commandId": "revoke-1",
            "coreId": "core-a",
            "homeId": "home-a",
            "accountId": "ada",
            "sessionId": "session-a",
            "coreRevision": 3,
            "homeRevision": 5,
            "accountRevision": 9,
            "membersRevision": 11,
            "cameraId": "camera-door",
            "cameraRevision": 13,
            "eventId": "event-99",
            "eventRevision": 17,
            "sessionRevision": 19,
            "expectedShareRevision": revision,
            "shareId": share_id,
        },
        sort_keys=True,
        separators=(",", ":"),
    ).encode()


def store(path: Path) -> PrivateEventShareStore:
    database = Database(path)
    if not path.exists():
        database.create_schema()
    with database.transaction() as connection:
        migrate_private_event_sharing(connection)
    return PrivateEventShareStore(
        database,
        encryption_key=ENCRYPTION_KEY,
        audit_key=AUDIT_KEY,
        transformation_key=TRANSFORM_KEY,
        clock=lambda: NOW,
    )


def test_explicit_consent_and_redaction_proof_are_closed_scopes(tmp_path):
    shares = store(tmp_path / "core.sqlite3")
    receipt = shares.create(
        actor("ada"),
        command_bytes=create_bytes(),
        authority=authority(),
        consent=consent(),
    )
    assert receipt.share_revision == 8
    assert receipt.access_token
    assert receipt.share.recipient_id == "recipient-a"
    assert receipt.share.mask_types == ("face", "license_plate")
    assert receipt.share.removed_metadata == ("device_serial", "gps")
    assert not hasattr(receipt.share, "source_artifact_id")

    missing_face = evidence(masks=("license_plate",))
    with pytest.raises(ApiError, match="transformation_unverified"):
        shares.create(
            actor("ada"),
            command_bytes=create_bytes(
                command_id="share-2",
                share_revision=8,
                evidence_value=missing_face,
            ),
            authority=authority(share_revision=8),
            consent=consent(),
        )
    with pytest.raises(ApiError, match="consent_scope_changed"):
        shares.create(
            actor("ada"),
            command_bytes=create_bytes(
                command_id="share-3",
                share_revision=8,
                expires_at=NOW + 601,
            ),
            authority=authority(share_revision=8),
            consent=consent(),
        )


def test_one_time_expiry_revoke_and_byte_exact_idempotency_fail_closed(tmp_path):
    shares = store(tmp_path / "core.sqlite3")
    command = create_bytes()
    created = shares.create(
        actor("ada"), command_bytes=command, authority=authority(), consent=consent()
    )
    assert (
        shares.create(
            actor("ada"),
            command_bytes=command,
            authority=authority(),
            consent=consent(),
        )
        == created
    )
    with pytest.raises(ApiError, match="idempotency_conflict"):
        shares.create(
            actor("ada"),
            command_bytes=json.dumps(json.loads(command), indent=2).encode(),
            authority=authority(),
            consent=consent(),
        )

    access = shares.redeem(
        recipient_id="recipient-a",
        access_token=created.access_token,
        access_id="access-1",
        now=NOW + 1,
    )
    assert set(access) == {"shareId", "outputArtifactId", "outputDigest", "expiresAt"}
    with pytest.raises(ApiError, match="share_unavailable"):
        shares.redeem(
            recipient_id="recipient-a",
            access_token=created.access_token,
            access_id="access-2",
            now=NOW + 2,
        )

    timed = shares.create(
        actor("ada"),
        command_bytes=create_bytes(
            command_id="share-timed",
            share_revision=9,
            mode="time_bound",
        ),
        authority=authority(share_revision=9),
        consent=consent(mode="time_bound"),
    )
    revoked = shares.revoke(
        actor("ada"),
        command_bytes=revoke_bytes(share_id=timed.share.id, revision=10),
        authority=authority(share_revision=10),
    )
    assert revoked.share_revision == 11
    with pytest.raises(ApiError, match="share_unavailable"):
        shares.redeem(
            recipient_id="recipient-a",
            access_token=timed.access_token,
            access_id="access-revoked",
            now=NOW + 1,
        )


def test_encrypted_audit_and_secret_free_role_scoped_export(tmp_path):
    path = tmp_path / "core.sqlite3"
    shares = store(path)
    created = shares.create(
        actor("ada"),
        command_bytes=create_bytes(),
        authority=authority(),
        consent=consent(),
    )
    with Database(path).connection() as connection:
        row = connection.execute(
            "SELECT ciphertext,token_hash FROM private_event_shares WHERE id=?",
            (created.share.id,),
        ).fetchone()
    assert b"recipient-a" not in row["ciphertext"]
    assert created.access_token.encode() not in row["ciphertext"]
    assert created.access_token not in row["token_hash"]

    exported = shares.export(
        actor("ada"), authority=authority(share_revision=8), limit=20
    )
    assert set(exported) == {
        "schemaVersion",
        "coreId",
        "homeId",
        "cameraId",
        "eventId",
        "shareRevision",
        "shares",
    }
    assert all(
        not any(
            term in key.lower()
            for term in ("token", "source", "proof", "nonce", "cipher", "key")
        )
        for item in exported["shares"]
        for key in item
    )
    with pytest.raises(ApiError, match="forbidden"):
        shares.export(
            actor("baran"), authority=authority("baran", share_revision=8), limit=20
        )

    with Database(path).transaction() as connection:
        connection.execute(
            "UPDATE private_event_share_events SET recipient_id='mallory' WHERE action='created'"
        )
    with pytest.raises(StartupError, match="private_event_share_history_invalid"):
        store(path).export(
            actor("ada"), authority=authority(share_revision=8), limit=20
        )
