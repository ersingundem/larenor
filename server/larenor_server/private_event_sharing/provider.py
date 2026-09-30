"""Normal Core authority, consent, source and redaction provider for F42."""

from __future__ import annotations

from dataclasses import dataclass
from fractions import Fraction
import hashlib
import hmac
import json
import math
import os
from pathlib import Path
import re
import secrets
import selectors
import signal
import sqlite3
import stat
import subprocess
import tempfile
import threading
import time
import uuid

from cryptography.exceptions import InvalidTag
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

from ..auth import Principal
from ..errors import ApiError, StartupError
from ..vault import validate_json_bounds
from .integration import RedactedEventArtifact
from .service import (
    ACCESS_MODES,
    MASK_TYPES,
    MAX_ACCESS_SECONDS,
    MAX_MEDIA_BYTES,
    METADATA_TYPES,
    EventShareAuthority,
    EventShareConsent,
)


_ID = re.compile(r"^[0-9a-f]{32}$")
_PIPELINE_ID = hashlib.sha256(b"larenor-ffmpeg-full-frame-blur-v1").hexdigest()[:32]
_MAX_BINDINGS = 2048
_MAX_CONSENTS = 4096
_MAX_ARTIFACTS = 64
_PREVIEW_LIFETIME = MAX_ACCESS_SECONDS
_MAX_VIDEO_DIMENSION = 4096
_MAX_VIDEO_PIXELS = 4096 * 2160
_MAX_VIDEO_SECONDS = 60
_MAX_VIDEO_RATE = 60
_MAX_VIDEO_FRAMES = _MAX_VIDEO_SECONDS * _MAX_VIDEO_RATE + 2
_MAX_STREAMS = 4
_MAX_PROCESS_STDOUT = 1024 * 1024
_MAX_PROCESS_STDERR = 256 * 1024
_MAX_FFMPEG_ALLOCATION = 64 * 1024 * 1024
_REDACTION_SLOT = threading.BoundedSemaphore(1)


def _canonical(value: object) -> bytes:
    return json.dumps(
        value, ensure_ascii=False, sort_keys=True, separators=(",", ":")
    ).encode()


def _safe_text(value: object, maximum: int) -> bool:
    return (
        isinstance(value, str)
        and value == value.strip()
        and 1 <= len(value) <= maximum
        and not any(
            ord(character) < 32
            or ord(character) == 127
            or 0xD800 <= ord(character) <= 0xDFFF
            for character in value
        )
    )


def _revision(key: bytes, domain: bytes, value: object) -> int:
    digest = hmac.new(key, domain + b"\0" + _canonical(value), hashlib.sha256).digest()
    return (int.from_bytes(digest[:7], "big") & (2**52 - 1)) or 1


@dataclass(frozen=True)
class PrivateEventPolicy:
    revision: int
    active: bool
    grantor_ids: tuple[str, ...]
    recipient_ids: tuple[str, ...]
    purposes: tuple[str, ...]
    access_modes: tuple[str, ...]
    max_ttl_seconds: int
    required_masks: tuple[str, ...]
    required_metadata: tuple[str, ...]
    redaction_mode: str = "full_frame_blur"

    def __post_init__(self):
        if (
            type(self.revision) is not int
            or not 1 <= self.revision < 2**63
            or type(self.active) is not bool
            or not 1 <= len(self.grantor_ids) <= 128
            or not 1 <= len(self.recipient_ids) <= 128
            or len(set(self.grantor_ids)) != len(self.grantor_ids)
            or len(set(self.recipient_ids)) != len(self.recipient_ids)
            or any(not _ID.fullmatch(value) for value in self.grantor_ids)
            or any(not _ID.fullmatch(value) for value in self.recipient_ids)
            or not 1 <= len(self.purposes) <= 16
            or len(set(self.purposes)) != len(self.purposes)
            or any(not _safe_text(value, 200) for value in self.purposes)
            or not self.access_modes
            or len(set(self.access_modes)) != len(self.access_modes)
            or not set(self.access_modes).issubset(ACCESS_MODES)
            or type(self.max_ttl_seconds) is not int
            or not 60 <= self.max_ttl_seconds <= MAX_ACCESS_SECONDS
            or not self.required_masks
            or len(set(self.required_masks)) != len(self.required_masks)
            or not set(self.required_masks).issubset(MASK_TYPES)
            or not self.required_metadata
            or len(set(self.required_metadata)) != len(self.required_metadata)
            or not set(self.required_metadata).issubset(METADATA_TYPES)
            or self.redaction_mode != "full_frame_blur"
        ):
            raise ValueError("invalid_private_event_policy")

    def payload(self) -> dict:
        return {
            "active": self.active,
            "grantorIds": list(self.grantor_ids),
            "recipientIds": list(self.recipient_ids),
            "purposes": list(self.purposes),
            "accessModes": list(self.access_modes),
            "maxTtlSeconds": self.max_ttl_seconds,
            "requiredMasks": list(self.required_masks),
            "requiredMetadata": list(self.required_metadata),
            "redactionMode": self.redaction_mode,
        }


class _EncryptedProviderStore:
    def __init__(self, database, key: bytes, clock=time.time):
        self.database, self.clock = database, clock
        self._cipher = AESGCM(hmac.new(key, b"f42-provider-encryption-v1", hashlib.sha256).digest())
        self._audit = hmac.new(key, b"f42-provider-audit-v1", hashlib.sha256).digest()

    def _hash(self, domain: bytes, values: object) -> str:
        return hmac.new(
            self._audit,
            b"larenor-private-event-provider-" + domain + b"-v1\0" + _canonical(values),
            hashlib.sha256,
        ).hexdigest()

    @staticmethod
    def _aad(domain: str, identity: str, revision: int) -> bytes:
        return f"larenor-private-event-{domain}-v1\0{identity}\0{revision}".encode()

    def _encrypt(self, domain: str, identity: str, revision: int, value: dict):
        nonce = secrets.token_bytes(12)
        ciphertext = self._cipher.encrypt(
            nonce, _canonical(value), self._aad(domain, identity, revision)
        )
        return nonce, ciphertext

    def _decrypt(self, domain: str, identity: str, revision: int, nonce, ciphertext):
        try:
            raw = self._cipher.decrypt(
                nonce, ciphertext, self._aad(domain, identity, revision)
            )
            value = json.loads(raw)
            if not isinstance(value, dict):
                raise ValueError
            return value
        except (InvalidTag, UnicodeDecodeError, json.JSONDecodeError, TypeError, ValueError):
            raise StartupError("private_event_share_provider_storage_invalid") from None

    def policy(self) -> PrivateEventPolicy | None:
        with self.database.connection() as connection:
            row = connection.execute(
                "SELECT * FROM private_event_share_policy WHERE singleton=1"
            ).fetchone()
        if row is None:
            return None
        expected = self._hash(
            b"policy",
            [row["revision"], bytes(row["nonce"]).hex(), hashlib.sha256(row["ciphertext"]).hexdigest(), row["updated_at"], row["updated_by"]],
        )
        if not hmac.compare_digest(row["record_hash"], expected):
            raise StartupError("private_event_share_provider_storage_invalid")
        value = self._decrypt("policy", "singleton", row["revision"], row["nonce"], row["ciphertext"])
        try:
            return PrivateEventPolicy(
                revision=row["revision"],
                active=value["active"],
                grantor_ids=tuple(value["grantorIds"]),
                recipient_ids=tuple(value["recipientIds"]),
                purposes=tuple(value["purposes"]),
                access_modes=tuple(value["accessModes"]),
                max_ttl_seconds=value["maxTtlSeconds"],
                required_masks=tuple(value["requiredMasks"]),
                required_metadata=tuple(value["requiredMetadata"]),
                redaction_mode=value["redactionMode"],
            )
        except (KeyError, TypeError, ValueError):
            raise StartupError("private_event_share_provider_storage_invalid") from None

    def put_policy(self, expected_revision: int, actor_id: str, values: dict) -> PrivateEventPolicy:
        if not _ID.fullmatch(actor_id):
            raise ApiError("invalid_request", 400)
        with self.database.transaction() as connection:
            row = connection.execute(
                "SELECT revision FROM private_event_share_policy WHERE singleton=1"
            ).fetchone()
            current = 0 if row is None else row["revision"]
            if current != expected_revision or current >= 2**63 - 1:
                raise ApiError("revision_conflict", 409)
            policy = PrivateEventPolicy(revision=current + 1, **values)
            nonce, ciphertext = self._encrypt(
                "policy", "singleton", policy.revision, policy.payload()
            )
            now = self.clock()
            record_hash = self._hash(
                b"policy",
                [policy.revision, nonce.hex(), hashlib.sha256(ciphertext).hexdigest(), now, actor_id],
            )
            connection.execute(
                "INSERT INTO private_event_share_policy VALUES(1,?,?,?,?,?,?) "
                "ON CONFLICT(singleton) DO UPDATE SET revision=excluded.revision,"
                "nonce=excluded.nonce,ciphertext=excluded.ciphertext,record_hash=excluded.record_hash,"
                "updated_at=excluded.updated_at,updated_by=excluded.updated_by",
                (policy.revision, nonce, ciphertext, record_hash, now, actor_id),
            )
        return policy

    def binding(self, camera_id: str, event_id: str) -> dict | None:
        with self.database.connection() as connection:
            row = connection.execute(
                "SELECT * FROM private_event_share_bindings WHERE camera_id=? AND event_id=?",
                (camera_id, event_id),
            ).fetchone()
        if row is None:
            return None
        identity = camera_id + ":" + event_id
        expected = self._hash(
            b"binding",
            [camera_id, event_id, row["revision"], bytes(row["nonce"]).hex(),
             hashlib.sha256(row["ciphertext"]).hexdigest(), row["expires_at"], row["updated_at"]],
        )
        if not hmac.compare_digest(row["record_hash"], expected):
            raise StartupError("private_event_share_provider_storage_invalid")
        value = self._decrypt(
            "binding", identity, row["revision"], row["nonce"], row["ciphertext"]
        )
        if value.get("cameraId") != camera_id or value.get("eventId") != event_id:
            raise StartupError("private_event_share_provider_storage_invalid")
        value["revision"] = row["revision"]
        value["expiresAt"] = row["expires_at"]
        return value

    def put_binding(self, value: dict) -> dict:
        camera_id, event_id = value.get("cameraId"), value.get("eventId")
        expires = value.get("expiresAt")
        if (
            not isinstance(camera_id, str)
            or not _ID.fullmatch(camera_id)
            or not isinstance(event_id, str)
            or not _ID.fullmatch(event_id)
            or type(expires) not in (int, float)
            or not math.isfinite(expires)
            or expires <= self.clock()
        ):
            raise ApiError("share_unavailable", 503)
        identity = camera_id + ":" + event_id
        with self.database.transaction() as connection:
            count = connection.execute(
                "SELECT COUNT(*) FROM private_event_share_bindings"
            ).fetchone()[0]
            row = connection.execute(
                "SELECT revision FROM private_event_share_bindings WHERE camera_id=? AND event_id=?",
                (camera_id, event_id),
            ).fetchone()
            if row is None and count >= _MAX_BINDINGS:
                raise ApiError("share_unavailable", 503)
            revision = 1 if row is None else row["revision"] + 1
            payload = dict(value)
            payload.pop("expiresAt", None)
            nonce, ciphertext = self._encrypt("binding", identity, revision, payload)
            now = self.clock()
            record_hash = self._hash(
                b"binding",
                [camera_id, event_id, revision, nonce.hex(), hashlib.sha256(ciphertext).hexdigest(), expires, now],
            )
            connection.execute(
                "INSERT INTO private_event_share_bindings VALUES(?,?,?,?,?,?,?,?) "
                "ON CONFLICT(camera_id,event_id) DO UPDATE SET revision=excluded.revision,"
                "nonce=excluded.nonce,ciphertext=excluded.ciphertext,record_hash=excluded.record_hash,"
                "expires_at=excluded.expires_at,updated_at=excluded.updated_at",
                (camera_id, event_id, revision, nonce, ciphertext, record_hash, expires, now),
            )
        return self.binding(camera_id, event_id)

    def put_consent(self, consent: EventShareConsent, policy_revision: int) -> None:
        payload = {
            "grantedBy": consent.granted_by,
            "recipientId": consent.recipient_id,
            "coreId": consent.core_id,
            "homeId": consent.home_id,
            "cameraId": consent.camera_id,
            "eventId": consent.event_id,
            "coreRevision": consent.core_revision,
            "homeRevision": consent.home_revision,
            "accountRevision": consent.account_revision,
            "membersRevision": consent.members_revision,
            "cameraRevision": consent.camera_revision,
            "eventRevision": consent.event_revision,
            "purpose": consent.purpose,
            "acceptedAt": consent.accepted_at,
            "expiresAt": consent.expires_at,
            "accessMode": consent.access_mode,
            "requiredMasks": list(consent.required_masks),
            "requiredMetadata": list(consent.required_metadata),
            "policyRevision": policy_revision,
        }
        nonce, ciphertext = self._encrypt("consent", consent.id, consent.revision, payload)
        record_hash = self._hash(
            b"consent",
            [consent.id, consent.revision, consent.granted_by, consent.recipient_id,
             consent.camera_id, consent.event_id, nonce.hex(),
             hashlib.sha256(ciphertext).hexdigest(), consent.expires_at, consent.accepted_at],
        )
        with self.database.transaction() as connection:
            if connection.execute(
                "SELECT COUNT(*) FROM private_event_share_consents"
            ).fetchone()[0] >= _MAX_CONSENTS:
                raise ApiError("private_event_share_limit_reached", 413)
            connection.execute(
                "INSERT INTO private_event_share_consents VALUES(?,?,?,?,?,?,?,?,?,?,?)",
                (consent.id, consent.revision, consent.granted_by, consent.recipient_id,
                 consent.camera_id, consent.event_id, nonce, ciphertext, record_hash,
                 consent.expires_at, consent.accepted_at),
            )

    def consent(self, consent_id: str) -> tuple[EventShareConsent, int] | None:
        with self.database.connection() as connection:
            row = connection.execute(
                "SELECT * FROM private_event_share_consents WHERE id=?", (consent_id,)
            ).fetchone()
        if row is None:
            return None
        value = self._decrypt("consent", row["id"], row["revision"], row["nonce"], row["ciphertext"])
        expected = self._hash(
            b"consent",
            [row["id"], row["revision"], row["issuer_id"], row["recipient_id"],
             row["camera_id"], row["event_id"], bytes(row["nonce"]).hex(),
             hashlib.sha256(row["ciphertext"]).hexdigest(), row["expires_at"], row["created_at"]],
        )
        if not hmac.compare_digest(row["record_hash"], expected):
            raise StartupError("private_event_share_provider_storage_invalid")
        try:
            consent = EventShareConsent(
                id=row["id"], revision=row["revision"],
                granted_by=value["grantedBy"], recipient_id=value["recipientId"],
                core_id=value["coreId"], home_id=value["homeId"],
                camera_id=value["cameraId"], event_id=value["eventId"],
                core_revision=value["coreRevision"], home_revision=value["homeRevision"],
                account_revision=value["accountRevision"], members_revision=value["membersRevision"],
                camera_revision=value["cameraRevision"], event_revision=value["eventRevision"],
                purpose=value["purpose"], accepted_at=value["acceptedAt"],
                expires_at=value["expiresAt"], access_mode=value["accessMode"],
                required_masks=tuple(value["requiredMasks"]),
                required_metadata=tuple(value["requiredMetadata"]),
            )
            policy_revision = value["policyRevision"]
            if type(policy_revision) is not int or policy_revision < 1:
                raise ValueError
            return consent, policy_revision
        except (KeyError, TypeError, ValueError):
            raise StartupError("private_event_share_provider_storage_invalid") from None

    def put_artifact(self, content: bytes, expires_at: float) -> str:
        if (
            not isinstance(content, bytes)
            or not 1 <= len(content) <= MAX_MEDIA_BYTES
            or not math.isfinite(expires_at)
            or expires_at <= self.clock()
        ):
            raise ApiError("transformation_unverified", 409)
        identifier, digest = uuid.uuid4().hex, hashlib.sha256(content).hexdigest()
        nonce = secrets.token_bytes(12)
        aad = f"larenor-private-event-artifact-v1\0{identifier}\0{digest}\0{len(content)}\0{expires_at:.6f}".encode()
        ciphertext = self._cipher.encrypt(nonce, content, aad)
        created = self.clock()
        record_hash = self._hash(
            b"artifact",
            [identifier, nonce.hex(), hashlib.sha256(ciphertext).hexdigest(), digest,
             len(content), expires_at, created],
        )
        with self.database.transaction() as connection:
            connection.execute(
                "DELETE FROM private_event_share_artifacts WHERE expires_at<=?", (created,)
            )
            if connection.execute(
                "SELECT COUNT(*) FROM private_event_share_artifacts"
            ).fetchone()[0] >= _MAX_ARTIFACTS:
                raise ApiError("private_event_share_limit_reached", 413)
            connection.execute(
                "INSERT INTO private_event_share_artifacts VALUES(?,?,?,?,?,?,?,?)",
                (identifier, nonce, ciphertext, digest, len(content), record_hash, expires_at, created),
            )
        return identifier

    def artifact(self, artifact_id: str, max_bytes: int) -> bytes:
        if not _ID.fullmatch(artifact_id) or not 1 <= max_bytes <= MAX_MEDIA_BYTES:
            raise ApiError("share_unavailable", 404)
        with self.database.connection() as connection:
            row = connection.execute(
                "SELECT * FROM private_event_share_artifacts WHERE id=?", (artifact_id,)
            ).fetchone()
        if row is None or row["expires_at"] <= self.clock() or row["byte_length"] > max_bytes:
            raise ApiError("share_unavailable", 404)
        try:
            return self._decode_artifact(row)
        except StartupError:
            raise ApiError("share_unavailable", 404) from None

    def _decode_artifact(self, row) -> bytes:
        expected = self._hash(
            b"artifact",
            [row["id"], bytes(row["nonce"]).hex(), hashlib.sha256(row["ciphertext"]).hexdigest(),
             row["digest"], row["byte_length"], row["expires_at"], row["created_at"]],
        )
        if not hmac.compare_digest(row["record_hash"], expected):
            raise StartupError("private_event_share_provider_storage_invalid")
        aad = f"larenor-private-event-artifact-v1\0{row['id']}\0{row['digest']}\0{row['byte_length']}\0{row['expires_at']:.6f}".encode()
        try:
            content = self._cipher.decrypt(row["nonce"], row["ciphertext"], aad)
        except InvalidTag:
            raise StartupError("private_event_share_provider_storage_invalid") from None
        if len(content) != row["byte_length"] or not hmac.compare_digest(
            hashlib.sha256(content).hexdigest(), row["digest"]
        ):
            raise StartupError("private_event_share_provider_storage_invalid")
        return content

    def validate_storage(self):
        self.policy()
        with self.database.connection() as connection:
            bindings = connection.execute(
                "SELECT camera_id,event_id FROM private_event_share_bindings"
            ).fetchall()
            consents = connection.execute(
                "SELECT id FROM private_event_share_consents"
            ).fetchall()
            artifacts = connection.execute(
                "SELECT * FROM private_event_share_artifacts"
            ).fetchall()
        if len(bindings) > _MAX_BINDINGS or len(consents) > _MAX_CONSENTS or len(artifacts) > _MAX_ARTIFACTS:
            raise StartupError("private_event_share_provider_storage_invalid")
        for row in bindings:
            self.binding(row["camera_id"], row["event_id"])
        for row in consents:
            self.consent(row["id"])
        for row in artifacts:
            # Expiry affects redemption, not startup authentication of retained rows.
            self._decode_artifact(row)


class FfmpegFullFrameRedactor:
    """Fixed full-frame privacy transform; this is deliberately not a detector."""

    def __init__(self, ffmpeg: Path, ffprobe: Path, work_root: Path, store, clock=time.time):
        self.ffmpeg = self._binary(ffmpeg)
        self.ffprobe = self._binary(ffprobe)
        self.work_root, self.store, self.clock = work_root, store, clock
        work_root.mkdir(mode=0o700, parents=True, exist_ok=True)
        info = work_root.stat()
        if (
            not stat.S_ISDIR(info.st_mode)
            or info.st_uid != os.geteuid()
            or info.st_mode & 0o077
        ):
            raise StartupError("private_event_redaction_unavailable")

    @staticmethod
    def _binary(value: Path) -> str:
        if not isinstance(value, Path) or not value.is_absolute():
            raise StartupError("private_event_redaction_unavailable")
        try:
            resolved = value.resolve(strict=True)
            info = resolved.stat()
        except OSError:
            raise StartupError("private_event_redaction_unavailable") from None
        if not stat.S_ISREG(info.st_mode) or not os.access(resolved, os.X_OK):
            raise StartupError("private_event_redaction_unavailable")
        return str(resolved)

    @staticmethod
    def _terminate(process):
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except (OSError, ProcessLookupError):
            try:
                process.kill()
            except OSError:
                pass
        try:
            process.wait(timeout=2)
        except (OSError, subprocess.TimeoutExpired):
            pass

    @classmethod
    def _run(cls, command: list[str], timeout: int, guard=lambda: None) -> bytes:
        if not callable(guard):
            raise ApiError("share_unavailable", 503)
        process = None
        selector = selectors.DefaultSelector()
        output, errors = bytearray(), bytearray()
        failure = None
        try:
            guard()
            process = subprocess.Popen(
                command,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                env={"PATH": "/usr/bin:/bin", "LC_ALL": "C", "LANG": "C"},
                start_new_session=True,
            )
            if process.stdout is None or process.stderr is None:
                raise OSError
            for stream, target, maximum in (
                (process.stdout, output, _MAX_PROCESS_STDOUT),
                (process.stderr, errors, _MAX_PROCESS_STDERR),
            ):
                os.set_blocking(stream.fileno(), False)
                selector.register(stream, selectors.EVENT_READ, (target, maximum))
            deadline = time.monotonic() + timeout
            while selector.get_map():
                try:
                    guard()
                except ApiError as error:
                    failure = error
                    break
                except Exception:
                    failure = ApiError("share_unavailable", 503)
                    break
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    failure = "timeout"
                    break
                for key, _events in selector.select(min(remaining, 0.1)):
                    target, maximum = key.data
                    try:
                        chunk = os.read(key.fileobj.fileno(), 64 * 1024)
                    except BlockingIOError:
                        continue
                    if not chunk:
                        selector.unregister(key.fileobj)
                        key.fileobj.close()
                    elif len(target) + len(chunk) > maximum:
                        failure = "output_limit"
                        break
                    else:
                        target.extend(chunk)
                if failure is not None:
                    break
            if failure is None:
                while process.poll() is None:
                    try:
                        guard()
                    except ApiError as error:
                        failure = error
                        break
                    except Exception:
                        failure = ApiError("share_unavailable", 503)
                        break
                    remaining = deadline - time.monotonic()
                    if remaining <= 0:
                        failure = "timeout"
                        break
                    time.sleep(min(remaining, 0.1))
            if failure is not None:
                cls._terminate(process)
            elif process.returncode != 0:
                failure = "process_failed"
        except OSError:
            if process is not None:
                cls._terminate(process)
            raise ApiError("share_unavailable", 503) from None
        finally:
            selector.close()
            if process is not None:
                for stream in (process.stdout, process.stderr):
                    if stream is not None and not stream.closed:
                        stream.close()
        if isinstance(failure, ApiError):
            raise failure
        if failure == "timeout":
            raise ApiError("share_unavailable", 503)
        if failure is not None:
            raise ApiError("transformation_unverified", 409)
        return bytes(output)

    def _probe(self, path: Path, *, count_frames: bool, guard=lambda: None) -> dict:
        count = ["-count_frames"] if count_frames else []
        raw = self._run(
            [
                self.ffprobe, "-v", "error", "-max_alloc",
                str(_MAX_FFMPEG_ALLOCATION), "-protocol_whitelist", "file,pipe",
                *count, "-show_streams", "-show_format",
                "-show_chapters", "-of", "json", str(path),
            ],
            15,
            guard,
        )
        try:
            def pairs(items):
                value = {}
                for key, item in items:
                    if key in value:
                        raise ValueError
                    value[key] = item
                return value

            value = json.loads(
                raw,
                object_pairs_hook=pairs,
                parse_constant=lambda _value: (_ for _ in ()).throw(ValueError()),
            )
            validate_json_bounds(value)
        except (
            ApiError, UnicodeDecodeError, json.JSONDecodeError,
            RecursionError, TypeError, ValueError,
        ):
            raise ApiError("transformation_unverified", 409) from None
        if (
            not isinstance(value, dict)
            or not isinstance(value.get("streams"), list)
            or not isinstance(value.get("format"), dict)
            or len(value["streams"]) > _MAX_STREAMS
        ):
            raise ApiError("transformation_unverified", 409)
        return value

    @staticmethod
    def _video(probe: dict) -> dict:
        videos = [stream for stream in probe["streams"] if stream.get("codec_type") == "video"]
        if len(videos) != 1:
            raise ApiError("transformation_unverified", 409)
        value = videos[0]
        if (
            type(value.get("width")) is not int
            or type(value.get("height")) is not int
            or not 16 <= value["width"] <= _MAX_VIDEO_DIMENSION
            or not 16 <= value["height"] <= _MAX_VIDEO_DIMENSION
            or value["width"] * value["height"] > _MAX_VIDEO_PIXELS
        ):
            raise ApiError("transformation_unverified", 409)
        return value

    @staticmethod
    def _timeline_header(probe: dict, video: dict) -> tuple[float, Fraction]:
        try:
            duration = float(probe["format"]["duration"])
            frame_rate = Fraction(video["avg_frame_rate"])
        except (KeyError, TypeError, ValueError, ZeroDivisionError):
            raise ApiError("transformation_unverified", 409) from None
        if (
            not math.isfinite(duration)
            or not 0.04 <= duration <= _MAX_VIDEO_SECONDS
            or not Fraction(1, 10) <= frame_rate <= _MAX_VIDEO_RATE
        ):
            raise ApiError("transformation_unverified", 409)
        return duration, frame_rate

    @classmethod
    def _timeline(cls, probe: dict, video: dict) -> tuple[float, int, Fraction]:
        duration, frame_rate = cls._timeline_header(probe, video)
        try:
            frames = int(video["nb_read_frames"])
        except (KeyError, TypeError, ValueError):
            raise ApiError("transformation_unverified", 409) from None
        if not 1 <= frames <= _MAX_VIDEO_FRAMES:
            raise ApiError("transformation_unverified", 409)
        return duration, frames, frame_rate

    @staticmethod
    def _metadata_removed(probe: dict) -> bool:
        allowed_format = {"major_brand", "minor_version", "compatible_brands", "encoder"}
        allowed_stream = {"language", "handler_name", "vendor_id", "encoder"}
        format_tags = probe.get("format", {}).get("tags", {})
        if (
            not isinstance(format_tags, dict)
            or not set(format_tags).issubset(allowed_format)
            or not re.fullmatch(r"[A-Za-z0-9]{4}", format_tags.get("major_brand", ""))
            or not re.fullmatch(r"[0-9]{1,10}", format_tags.get("minor_version", ""))
            or not re.fullmatch(
                r"[A-Za-z0-9]{4,64}", format_tags.get("compatible_brands", "")
            )
            or not re.fullmatch(r"Lavf[0-9.]{3,32}", format_tags.get("encoder", ""))
        ):
            return False
        for stream in probe["streams"]:
            tags = stream.get("tags", {})
            kind = stream.get("codec_type")
            if (
                not isinstance(tags, dict)
                or not set(tags).issubset(allowed_stream)
                or tags.get("language") not in (None, "und")
                or tags.get("handler_name")
                not in (None, "VideoHandler" if kind == "video" else "SoundHandler")
                or tags.get("vendor_id") not in (None, "[0][0][0][0]")
                or (
                    "encoder" in tags
                    and re.fullmatch(r"Lavc[0-9.]{3,32}(?: [A-Za-z0-9_.-]{1,32})?", tags["encoder"])
                    is None
                )
            ):
                return False
        return True

    def __call__(
        self, authority, source, masks, removed_metadata, max_bytes,
        *, guard=lambda: None,
    ):
        if (
            not isinstance(authority, EventShareAuthority)
            or not isinstance(source, bytes)
            or not 24 <= len(source) <= max_bytes <= MAX_MEDIA_BYTES
            or not masks
            or not set(masks).issubset(MASK_TYPES)
            or not removed_metadata
            or not set(removed_metadata).issubset(METADATA_TYPES)
            or not callable(guard)
        ):
            raise ApiError("transformation_unverified", 409)
        if not _REDACTION_SLOT.acquire(blocking=False):
            raise ApiError("share_unavailable", 503)
        try:
            return self._redact(
                authority, source, masks, removed_metadata, max_bytes, guard
            )
        finally:
            _REDACTION_SLOT.release()

    def _redact(self, authority, source, masks, removed_metadata, max_bytes, guard):
        with tempfile.TemporaryDirectory(prefix="redact-", dir=self.work_root) as directory:
            root = Path(directory)
            os.chmod(root, 0o700)
            source_path, output_path = root / "source.mp4", root / "redacted.mp4"
            fd = os.open(source_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
            try:
                with os.fdopen(fd, "wb", closefd=True) as handle:
                    handle.write(source)
                    handle.flush()
                    os.fsync(handle.fileno())
            except BaseException:
                try:
                    os.close(fd)
                except OSError:
                    pass
                raise
            guard()
            header = self._probe(source_path, count_frames=False, guard=guard)
            source_header_video = self._video(header)
            self._timeline_header(header, source_header_video)
            before = self._probe(source_path, count_frames=True, guard=guard)
            source_video = self._video(before)
            source_duration, source_frames, source_rate = self._timeline(
                before, source_video
            )
            if (
                (source_video["width"], source_video["height"])
                != (source_header_video["width"], source_header_video["height"])
                or sum(stream.get("codec_type") == "audio" for stream in before["streams"]) > 2
                or any(stream.get("codec_type") not in {"video", "audio", "subtitle", "data", "attachment"}
                       for stream in before["streams"])
            ):
                raise ApiError("transformation_unverified", 409)
            command = [
                self.ffmpeg, "-v", "error", "-nostdin", "-xerror", "-y",
                "-max_alloc", str(_MAX_FFMPEG_ALLOCATION),
                "-protocol_whitelist", "file,pipe",
                "-i", str(source_path), "-map", "0:v:0", "-map", "0:a:0?",
                "-sn", "-dn",
                "-vf", "boxblur=luma_radius=min(h\\,w)/12:luma_power=4:"
                "chroma_radius=min(cw\\,ch)/12:chroma_power=4",
                "-c:v", "mpeg4", "-q:v", "5", "-threads", "1",
                "-c:a", "aac", "-b:a", "128k",
                "-map_metadata", "-1", "-map_chapters", "-1",
                "-metadata", "title=", "-metadata", "comment=",
                "-movflags", "+faststart", str(output_path),
            ]
            self._run(command, 60, guard)
            try:
                info = output_path.lstat()
                if (
                    not stat.S_ISREG(info.st_mode)
                    or info.st_uid != os.geteuid()
                    or info.st_nlink != 1
                    or not 24 <= info.st_size <= max_bytes
                ):
                    raise ApiError("transformation_unverified", 409)
                content = output_path.read_bytes()
            except OSError:
                raise ApiError("transformation_unverified", 409) from None
            after = self._probe(output_path, count_frames=True, guard=guard)
            output_video = self._video(after)
            output_duration, output_frames, output_rate = self._timeline(
                after, output_video
            )
            duration_tolerance = max(
                0.25, float(Fraction(2, 1) / min(source_rate, output_rate))
            )
            if (
                (output_video["width"], output_video["height"])
                != (source_video["width"], source_video["height"])
                or output_frames != source_frames
                or abs(output_duration - source_duration) > duration_tolerance
                or any(stream.get("codec_type") not in {"video", "audio"} for stream in after["streams"])
                or after.get("chapters") not in (None, [])
                or not self._metadata_removed(after)
                or hashlib.sha256(source).digest() == hashlib.sha256(content).digest()
            ):
                raise ApiError("transformation_unverified", 409)
            self._run(
                [self.ffmpeg, "-v", "error", "-nostdin", "-xerror",
                 "-max_alloc", str(_MAX_FFMPEG_ALLOCATION),
                 "-protocol_whitelist", "file,pipe", "-i",
                 str(output_path), "-map", "0:v:0", "-map", "0:a:0?", "-f", "null", "-"],
                30,
                guard,
            )
        artifact_id = self.store.put_artifact(content, self.clock() + _PREVIEW_LIFETIME)
        return RedactedEventArtifact(
            artifact_id=artifact_id,
            content=content,
            pipeline_id=_PIPELINE_ID,
            pipeline_revision=1,
            masks=tuple(sorted(set(masks))),
            removed_metadata=tuple(sorted(set(removed_metadata))),
        )


class CorePrivateEventSharingProvider:
    def __init__(self, core, database, key, context, share_store, camera_runtime, *, redactor=None, clock=time.time):
        self.core, self.database, self.context = core, database, context
        self.share_store, self.camera_runtime, self.clock = share_store, camera_runtime, clock
        self._revision_key = hmac.new(key, b"f42-authority-revisions-v1", hashlib.sha256).digest()
        self.store = _EncryptedProviderStore(database, key, clock)
        self.redaction_worker = redactor
        self.store.validate_storage()

    def _members(self, actor):
        with self.database.connection() as connection:
            self.core.auth.assert_current(connection, actor)
            account = connection.execute(
                "SELECT revision,role,disabled,must_change_password FROM users WHERE id=?", (actor.id,)
            ).fetchone()
            members = connection.execute(
                "SELECT id,revision FROM users WHERE disabled=0 AND must_change_password=0 ORDER BY id"
            ).fetchall()
            home_revision = self.core.home_resources._state(connection)["revision"]
        if account is None or account["disabled"] or account["must_change_password"]:
            raise ApiError("invalid_session", 401)
        member_ids = tuple(row["id"] for row in members)
        if actor.id not in member_ids:
            raise ApiError("forbidden", 403)
        members_revision = _revision(
            self._revision_key, b"members", [[row["id"], row["revision"]] for row in members]
        )
        session_revision = _revision(
            self._revision_key, b"session", [actor.family_id, actor.token_id]
        )
        return account, member_ids, members_revision, home_revision, session_revision

    def _public_binding(self, value):
        evidence = value.get("evidence")
        if hasattr(evidence, "model_dump"):
            evidence = evidence.model_dump(mode="json")
        if (
            type(evidence) is not dict
            or value.get("schemaVersion") != 1
            or evidence.get("coreId") != self.context.coreId
            or evidence.get("homeId") != self.context.homeId
            or not _ID.fullmatch(str(evidence.get("cameraId", "")))
            or not _ID.fullmatch(str(evidence.get("eventId", "")))
            or type(evidence.get("captureRevision")) is not int
            or not 1 <= evidence["captureRevision"] <= 2**53 - 1
            or not isinstance(value.get("seal"), str)
            or type(value.get("cameraRevision")) is not int
            or type(value.get("sourceRevision")) is not int
            or type(value.get("expiresAtMs")) is not int
        ):
            raise ApiError("share_unavailable", 503)
        return evidence, {
            "schemaVersion": 1,
            "cameraId": evidence.get("cameraId"),
            "eventId": evidence.get("eventId"),
            "evidence": evidence,
            "seal": value["seal"],
            "cameraRevision": value["cameraRevision"],
            "sourceRevision": value["sourceRevision"],
            "expiresAt": value["expiresAtMs"] / 1000,
        }

    def _binding(self, actor, camera_id, event_id):
        if not _ID.fullmatch(camera_id) or not _ID.fullmatch(event_id):
            raise ApiError("not_found", 404)
        saved = self.store.binding(camera_id, event_id)
        live = False
        runtime = self.camera_runtime()
        if saved is None:
            minted = runtime.private_event_binding(
                self.core, actor, self.context.coreId, self.context.homeId,
                camera_id, event_id, ttl_seconds=MAX_ACCESS_SECONDS,
            )
            _evidence, payload = self._public_binding(minted)
            _account, members, _mr, _hr, _sr = self._members(actor)
            payload["ownerId"] = actor.id
            payload["memberIds"] = list(members)
            saved = self.store.put_binding(payload)
            live = True
        elif saved["expiresAt"] > self.clock() and saved.get("ownerId") == actor.id:
            try:
                authorized = runtime.authorize_private_event_binding(
                    self.core, actor, saved["seal"]
                )
                evidence, public = self._public_binding(authorized)
                live = (
                    evidence.get("cameraId") == camera_id
                    and evidence.get("eventId") == event_id
                    and public["cameraRevision"] == saved.get("cameraRevision")
                    and public["sourceRevision"] == saved.get("sourceRevision")
                )
            except ApiError:
                live = False
        if (
            saved.get("cameraId") != camera_id
            or saved.get("eventId") != event_id
            or saved.get("ownerId") is None
            or type(saved.get("memberIds")) is not list
            or saved["ownerId"] not in saved["memberIds"]
        ):
            raise ApiError("share_unavailable", 503)
        return saved, live

    def authority(self, actor: Principal, camera_id: str, event_id: str) -> EventShareAuthority:
        account, members, members_revision, home_revision, session_revision = self._members(actor)
        binding, live = self._binding(actor, camera_id, event_id)
        if actor.id not in binding["memberIds"] or actor.id not in members:
            raise ApiError("forbidden", 403)
        policy = self.store.policy()
        can_share = bool(
            live and policy and policy.active and actor.id in policy.grantor_ids
            and actor.role == "admin"
        )
        return EventShareAuthority(
            core_id=self.context.coreId, home_id=self.context.homeId,
            account_id=actor.id, session_id=actor.family_id,
            core_revision=1, home_revision=home_revision,
            account_revision=account["revision"], members_revision=members_revision,
            camera_id=camera_id, camera_revision=binding["cameraRevision"],
            event_id=event_id, event_revision=binding["evidence"]["captureRevision"],
            session_revision=session_revision,
            share_revision=self.share_store.current_revision(
                self.context.coreId, self.context.homeId, camera_id, event_id
            ),
            member_ids=members, can_share=can_share,
        )

    def event_reader(self, actor, authority, max_bytes):
        current = self.authority(actor, authority.camera_id, authority.event_id)
        if current != authority or not current.can_share:
            raise ApiError("authority_changed", 409)
        binding = self.store.binding(authority.camera_id, authority.event_id)
        if binding is None or binding["expiresAt"] <= self.clock():
            raise ApiError("share_unavailable", 503)
        return self.camera_runtime().read_private_event_clip(
            self.core, actor, binding["seal"], max_bytes
        )

    def consent_resolver(self, actor, consent_id):
        value = self.store.consent(consent_id)
        policy = self.store.policy()
        if value is None or policy is None:
            raise ApiError("consent_scope_changed", 409)
        consent, policy_revision = value
        if (
            consent.granted_by != actor.id
            or policy_revision != policy.revision
            or consent.expires_at <= self.clock()
        ):
            raise ApiError("consent_scope_changed", 409)
        return consent

    def artifact_reader(self, artifact_id, max_bytes):
        return self.store.artifact(artifact_id, max_bytes)

    def _redaction_guard(self, authority, masks, metadata):
        if (
            not isinstance(authority, EventShareAuthority)
            or (authority.core_id, authority.home_id)
            != (self.context.coreId, self.context.homeId)
            or not authority.can_share
        ):
            raise ApiError("authority_changed", 409)
        with self.database.connection() as connection:
            account = connection.execute(
                "SELECT revision,role,disabled,must_change_password FROM users WHERE id=?",
                (authority.account_id,),
            ).fetchone()
            family = connection.execute(
                "SELECT revoked_at,expires_at FROM session_families "
                "WHERE id=? AND user_id=?",
                (authority.session_id, authority.account_id),
            ).fetchone()
            members = connection.execute(
                "SELECT id,revision FROM users WHERE disabled=0 AND must_change_password=0 "
                "ORDER BY id"
            ).fetchall()
            home_revision = self.core.home_resources._state(connection)["revision"]
        member_ids = tuple(row["id"] for row in members)
        members_revision = _revision(
            self._revision_key,
            b"members",
            [[row["id"], row["revision"]] for row in members],
        )
        now = self.clock()
        if (
            account is None
            or family is None
            or account["revision"] != authority.account_revision
            or account["role"] != "admin"
            or account["disabled"]
            or account["must_change_password"]
            or family["revoked_at"] is not None
            or now >= family["expires_at"]
            or home_revision != authority.home_revision
            or member_ids != authority.member_ids
            or members_revision != authority.members_revision
        ):
            raise ApiError("authority_changed", 409)
        binding = self.store.binding(authority.camera_id, authority.event_id)
        policy = self.store.policy()
        if (
            binding is None
            or binding["expiresAt"] <= now
            or binding["cameraRevision"] != authority.camera_revision
            or binding["evidence"]["captureRevision"] != authority.event_revision
            or self.share_store.current_revision(
                authority.core_id, authority.home_id,
                authority.camera_id, authority.event_id,
            ) != authority.share_revision
            or policy is None
            or not policy.active
            or authority.account_id not in policy.grantor_ids
            or not set(policy.required_masks).issubset(masks)
            or not set(policy.required_metadata).issubset(metadata)
        ):
            raise ApiError("authority_changed", 409)

    def redact(self, authority, source, masks, metadata, max_bytes):
        if self.redaction_worker is None:
            raise ApiError("share_unavailable", 503)
        policy = self.store.policy()
        if (
            policy is None or not policy.active
            or not set(policy.required_masks).issubset(masks)
            or not set(policy.required_metadata).issubset(metadata)
        ):
            raise ApiError("consent_scope_changed", 409)
        guard = lambda: self._redaction_guard(authority, masks, metadata)
        guard()
        if isinstance(self.redaction_worker, FfmpegFullFrameRedactor):
            return self.redaction_worker(
                authority, source, masks, metadata, max_bytes, guard=guard
            )
        return self.redaction_worker(authority, source, masks, metadata, max_bytes)

    @staticmethod
    def policy_wire(policy):
        if policy is None:
            return {"schemaVersion": 1, "revision": 0, "configured": False}
        return {
            "schemaVersion": 1,
            "revision": policy.revision,
            "configured": True,
            **policy.payload(),
            "capability": {
                "schemaVersion": 1,
                "mode": "full_frame_blur",
                "targetedRecognition": False,
                "coversEntireFrame": True,
            },
        }

    def configure_policy(self, actor, core_id, home_id, values):
        if (core_id, home_id) != (self.context.coreId, self.context.homeId):
            raise ApiError("not_found", 404)
        if actor.role != "admin":
            raise ApiError("forbidden", 403)
        account, members, _mr, _hr, _sr = self._members(actor)
        if account["role"] != "admin":
            raise ApiError("forbidden", 403)
        grantors = tuple(values["grantor_ids"])
        recipients = tuple(values["recipient_ids"])
        if not set(grantors + recipients).issubset(members):
            raise ApiError("invalid_request", 400)
        policy = self.store.put_policy(
            values["expected_revision"], actor.id,
            {
                "active": values["active"],
                "grantor_ids": grantors,
                "recipient_ids": recipients,
                "purposes": tuple(values["purposes"]),
                "access_modes": tuple(values["access_modes"]),
                "max_ttl_seconds": values["max_ttl_seconds"],
                "required_masks": tuple(values["required_masks"]),
                "required_metadata": tuple(values["required_metadata"]),
                "redaction_mode": values["redaction_mode"],
            },
        )
        return self.policy_wire(policy)

    def policy(self, actor, core_id, home_id):
        if (core_id, home_id) != (self.context.coreId, self.context.homeId):
            raise ApiError("not_found", 404)
        if actor.role != "admin":
            raise ApiError("forbidden", 403)
        self._members(actor)
        return self.policy_wire(self.store.policy())

    def accept_consent(self, actor, camera_id, event_id, values):
        authority = self.authority(actor, camera_id, event_id)
        policy = self.store.policy()
        now = self.clock()
        if policy is None or not authority.can_share:
            raise ApiError("forbidden", 403)
        expected = values["authority"]
        if expected != {
            "coreRevision": authority.core_revision,
            "homeRevision": authority.home_revision,
            "accountRevision": authority.account_revision,
            "membersRevision": authority.members_revision,
            "cameraRevision": authority.camera_revision,
            "eventRevision": authority.event_revision,
            "sessionRevision": authority.session_revision,
            "expectedShareRevision": authority.share_revision,
        } or values["expected_policy_revision"] != policy.revision:
            raise ApiError("authority_changed", 409)
        recipient, purpose, mode = values["recipient_id"], values["purpose"], values["access_mode"]
        expires = values["expires_at"]
        masks, metadata = tuple(values["masks"]), tuple(values["removed_metadata"])
        if (
            recipient not in policy.recipient_ids
            or recipient not in authority.member_ids
            or purpose not in policy.purposes
            or mode not in policy.access_modes
            or type(expires) not in (int, float)
            or not math.isfinite(expires)
            or not now < expires <= now + policy.max_ttl_seconds
            or set(masks) != set(policy.required_masks)
            or set(metadata) != set(policy.required_metadata)
        ):
            raise ApiError("consent_scope_changed", 409)
        consent = EventShareConsent(
            id=uuid.uuid4().hex, revision=1, granted_by=actor.id,
            recipient_id=recipient, core_id=authority.core_id, home_id=authority.home_id,
            camera_id=camera_id, event_id=event_id,
            core_revision=authority.core_revision, home_revision=authority.home_revision,
            account_revision=authority.account_revision, members_revision=authority.members_revision,
            camera_revision=authority.camera_revision, event_revision=authority.event_revision,
            purpose=purpose, accepted_at=now, expires_at=expires, access_mode=mode,
            required_masks=tuple(sorted(masks)), required_metadata=tuple(sorted(metadata)),
        )
        self.store.put_consent(consent, policy.revision)
        return {
            "schemaVersion": 1,
            "consentId": consent.id,
            "revision": consent.revision,
            "recipientId": consent.recipient_id,
            "purpose": consent.purpose,
            "accessMode": consent.access_mode,
            "expiresAt": consent.expires_at,
            "requiredMasks": list(consent.required_masks),
            "requiredMetadata": list(consent.required_metadata),
        }
