from dataclasses import dataclass
import hashlib
import hmac
import json
from collections.abc import Callable

from ..auth import Principal
from ..errors import ApiError
from .models import CreateShareRequest, PreviewRequest, RevokeShareRequest
from .service import (
    EventShareAuthority,
    EventShareConsent,
    EventShareDownload,
    PrivateEventShareStore,
)


@dataclass(frozen=True)
class RedactedEventArtifact:
    artifact_id: str
    content: bytes
    pipeline_id: str
    pipeline_revision: int
    masks: tuple[str, ...]
    removed_metadata: tuple[str, ...]


AuthorityResolver = Callable[[Principal, str, str], EventShareAuthority]
ConsentResolver = Callable[[Principal, str], EventShareConsent]
EventReader = Callable[[Principal, EventShareAuthority, int], bytes]
RedactionWorker = Callable[
    [EventShareAuthority, bytes, tuple[str, ...], tuple[str, ...], int],
    RedactedEventArtifact,
]
ArtifactReader = Callable[[str, int], bytes]


class PrivateEventShareService:
    """Exact-authority adapter; every media byte comes from injected real providers."""

    def __init__(
        self,
        store: PrivateEventShareStore,
        *,
        authority_resolver: AuthorityResolver,
        consent_resolver: ConsentResolver,
        event_reader: EventReader,
        redaction_worker: RedactionWorker,
        artifact_reader: ArtifactReader,
    ):
        providers = (
            authority_resolver,
            consent_resolver,
            event_reader,
            redaction_worker,
            artifact_reader,
        )
        if not isinstance(store, PrivateEventShareStore) or not all(
            callable(provider) for provider in providers
        ):
            raise ValueError("invalid_private_event_share_providers")
        self.store = store
        self._authority_resolver = authority_resolver
        self._consent_resolver = consent_resolver
        self._event_reader = event_reader
        self._redaction_worker = redaction_worker
        self._artifact_reader = artifact_reader
        self.store.validate_storage()

    def _authority(
        self,
        actor: Principal,
        core_id: str,
        home_id: str,
        camera_id: str,
        event_id: str,
    ) -> EventShareAuthority:
        try:
            value = self._authority_resolver(actor, camera_id, event_id)
        except ApiError:
            raise
        except Exception:
            raise ApiError("share_unavailable", 404) from None
        if (
            not isinstance(value, EventShareAuthority)
            or value.core_id != core_id
            or value.home_id != home_id
            or value.camera_id != camera_id
            or value.event_id != event_id
            or value.account_id != actor.id
            or value.session_id != actor.family_id
        ):
            raise ApiError("authority_changed", 409)
        return value

    @staticmethod
    def _check(body, authority: EventShareAuthority) -> None:
        expected = (
            authority.core_revision,
            authority.home_revision,
            authority.account_revision,
            authority.members_revision,
            authority.camera_revision,
            authority.event_revision,
            authority.session_revision,
            authority.share_revision,
        )
        actual = (
            body.coreRevision,
            body.homeRevision,
            body.accountRevision,
            body.membersRevision,
            body.cameraRevision,
            body.eventRevision,
            body.sessionRevision,
            body.expectedShareRevision,
        )
        if actual != expected:
            raise ApiError("authority_changed", 409)

    @staticmethod
    def _authority_wire(value: EventShareAuthority) -> dict:
        return {
            "schemaVersion": 1,
            "coreId": value.core_id,
            "homeId": value.home_id,
            "accountId": value.account_id,
            "sessionId": value.session_id,
            "coreRevision": value.core_revision,
            "homeRevision": value.home_revision,
            "accountRevision": value.account_revision,
            "membersRevision": value.members_revision,
            "cameraId": value.camera_id,
            "cameraRevision": value.camera_revision,
            "eventId": value.event_id,
            "eventRevision": value.event_revision,
            "sessionRevision": value.session_revision,
            "shareRevision": value.share_revision,
            "canShare": value.can_share,
        }

    def context(self, actor, core_id, home_id, camera_id, event_id):
        return self._authority_wire(
            self._authority(actor, core_id, home_id, camera_id, event_id)
        )

    def preview(
        self, actor, core_id, home_id, camera_id, event_id, body: PreviewRequest
    ):
        authority = self._authority(actor, core_id, home_id, camera_id, event_id)
        self._check(body, authority)
        if not authority.can_share:
            raise ApiError("forbidden", 403)
        masks = tuple(sorted(set(body.masks)))
        metadata = tuple(sorted(set(body.removedMetadata)))
        if len(masks) != len(body.masks) or len(metadata) != len(body.removedMetadata):
            raise ApiError("invalid_request", 400)
        try:
            source = self._event_reader(actor, authority, 64 * 1024 * 1024)
            artifact = self._redaction_worker(
                authority, source, masks, metadata, 64 * 1024 * 1024
            )
        except ApiError:
            raise
        except Exception:
            raise ApiError("share_unavailable", 503) from None
        if not isinstance(artifact, RedactedEventArtifact):
            raise ApiError("transformation_unverified", 409)
        if self._authority(actor, core_id, home_id, camera_id, event_id) != authority:
            raise ApiError("authority_changed", 409)
        try:
            transformation = self.store.prepare_transformation(
                authority=authority,
                source=source,
                output=artifact.content,
                output_artifact_id=artifact.artifact_id,
                pipeline_id=artifact.pipeline_id,
                pipeline_revision=artifact.pipeline_revision,
                masks=artifact.masks,
                removed_metadata=artifact.removed_metadata,
            )
            covered = set(masks).issubset(artifact.masks) and set(
                metadata
            ).issubset(artifact.removed_metadata)
        except (TypeError, ValueError):
            raise ApiError("transformation_unverified", 409) from None
        if not covered:
            raise ApiError("transformation_unverified", 409)
        return {
            "authority": self._authority_wire(authority),
            "transformation": transformation,
        }

    def create(
        self, actor, core_id, home_id, camera_id, event_id, body: CreateShareRequest
    ):
        authority = self._authority(actor, core_id, home_id, camera_id, event_id)
        self._check(body, authority)
        if not authority.can_share:
            raise ApiError("forbidden", 403)
        try:
            consent = self._consent_resolver(actor, body.consentId)
        except ApiError:
            raise
        except Exception:
            raise ApiError("consent_scope_changed", 409) from None
        if not isinstance(consent, EventShareConsent):
            raise ApiError("consent_scope_changed", 409)
        try:
            source = self._event_reader(actor, authority, 64 * 1024 * 1024)
        except ApiError:
            raise
        except Exception:
            raise ApiError("share_unavailable", 503) from None
        if not isinstance(source, bytes) or not 1 <= len(source) <= 64 * 1024 * 1024:
            raise ApiError("share_unavailable", 503)
        transformation = body.transformation.model_dump()
        if hashlib.sha256(source).hexdigest() != transformation["sourceDigest"]:
            raise ApiError("transformation_unverified", 409)
        try:
            output = self._artifact_reader(
                transformation["outputArtifactId"], 64 * 1024 * 1024
            )
        except ApiError:
            raise
        except Exception:
            raise ApiError("transformation_unverified", 409) from None
        if (
            not isinstance(output, bytes)
            or not 1 <= len(output) <= 64 * 1024 * 1024
            or not hmac.compare_digest(
                hashlib.sha256(output).hexdigest(), transformation["outputDigest"]
            )
        ):
            raise ApiError("transformation_unverified", 409)
        if self._authority(actor, core_id, home_id, camera_id, event_id) != authority:
            raise ApiError("authority_changed", 409)
        try:
            if self._consent_resolver(actor, body.consentId) != consent:
                raise ApiError("consent_scope_changed", 409)
        except ApiError:
            raise
        except Exception:
            raise ApiError("consent_scope_changed", 409) from None
        command = {
            "action": "create",
            "commandId": body.commandId,
            "coreId": authority.core_id,
            "homeId": authority.home_id,
            "accountId": authority.account_id,
            "sessionId": authority.session_id,
            "coreRevision": body.coreRevision,
            "homeRevision": body.homeRevision,
            "accountRevision": body.accountRevision,
            "membersRevision": body.membersRevision,
            "cameraId": authority.camera_id,
            "cameraRevision": body.cameraRevision,
            "eventId": authority.event_id,
            "eventRevision": body.eventRevision,
            "sessionRevision": body.sessionRevision,
            "expectedShareRevision": body.expectedShareRevision,
            "consentId": body.consentId,
            "consentRevision": body.consentRevision,
            "recipientId": body.recipientId,
            "purpose": body.purpose,
            "expiresAt": body.expiresAt,
            "accessMode": body.accessMode,
            "transformation": transformation,
        }
        receipt = self.store.create(
            actor,
            command_bytes=json.dumps(
                command, sort_keys=True, separators=(",", ":")
            ).encode(),
            authority=authority,
            consent=consent,
        )
        return self._receipt(receipt)

    def revoke(
        self, actor, core_id, home_id, camera_id, event_id, body: RevokeShareRequest
    ):
        authority = self._authority(actor, core_id, home_id, camera_id, event_id)
        self._check(body, authority)
        command = {
            "action": "revoke",
            "commandId": body.commandId,
            "coreId": authority.core_id,
            "homeId": authority.home_id,
            "accountId": authority.account_id,
            "sessionId": authority.session_id,
            "coreRevision": body.coreRevision,
            "homeRevision": body.homeRevision,
            "accountRevision": body.accountRevision,
            "membersRevision": body.membersRevision,
            "cameraId": authority.camera_id,
            "cameraRevision": body.cameraRevision,
            "eventId": authority.event_id,
            "eventRevision": body.eventRevision,
            "sessionRevision": body.sessionRevision,
            "expectedShareRevision": body.expectedShareRevision,
            "shareId": body.shareId,
        }
        return self._receipt(
            self.store.revoke(
                actor,
                command_bytes=json.dumps(
                    command, sort_keys=True, separators=(",", ":")
                ).encode(),
                authority=authority,
            )
        )

    def snapshot(self, actor, core_id, home_id, camera_id, event_id, limit: int):
        authority = self._authority(actor, core_id, home_id, camera_id, event_id)
        return {
            "authority": self._authority_wire(authority),
            "export": self.store.export(actor, authority=authority, limit=limit),
            "audit": self.store.access_audit(actor, authority=authority, limit=limit),
        }

    def download(self, actor, core_id, home_id, camera_id, event_id, access_id, token):
        self._authority(actor, core_id, home_id, camera_id, event_id)
        return self.store.redeem_download(
            recipient_id=actor.id,
            access_token=token,
            access_id=access_id,
            artifact_reader=self._artifact_reader,
        )

    @staticmethod
    def _receipt(receipt):
        return {
            "auditId": receipt.audit_id,
            "commandId": receipt.command_id,
            "action": receipt.action,
            "shareRevision": receipt.share_revision,
            "accessToken": receipt.access_token,
            "share": {
                "id": receipt.share.id,
                "recipientId": receipt.share.recipient_id,
                "purpose": receipt.share.purpose,
                "accessMode": receipt.share.access_mode,
                "expiresAt": receipt.share.expires_at,
                "outputDigest": receipt.share.output_digest,
                "revoked": receipt.share.revoked_at is not None,
                "consumed": receipt.share.consumed_at is not None,
            },
        }
