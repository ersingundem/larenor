"""Durable, tamper-evident metadata store for F45 sound events."""

import hashlib
import hmac
import json
import os
import secrets
import sqlite3
from contextlib import contextmanager
from pathlib import Path

from ..errors import ApiError, StartupError
from .models import (
    SoundEvent,
    SoundEventAcknowledgement,
    SoundEventAcknowledgementRequest,
    SoundEventAuthority,
    SoundEventClientAuthority,
    SoundEventFeedbackReceipt,
    SoundEventFeedbackRequest,
    SoundEventNotificationPolicy,
    SoundEventPolicyReceipt,
    SoundEventPolicyRequest,
    SoundEventRecord,
    SoundEventSnapshot,
    SoundSourceStatus,
)

MAX_EVENTS = 10_000
MAX_RECEIPTS = 20_000
MAX_PREFERENCES = 128


class SoundEventRepository:
    """Stores classification metadata only; audio bytes and locations have no column."""

    def __init__(
        self, path, key, primary_db, auth, context, clock,
        source_status_provider=None,
    ):
        if not isinstance(key, bytes) or len(key) != 32:
            raise ValueError("invalid_key")
        self.path = Path(path)
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self._key = key
        self._primary = primary_db
        self._auth = auth
        self._context = context
        self._clock = clock
        if source_status_provider is not None and not callable(source_status_provider):
            raise ValueError("invalid_source_status_provider")
        self._source_status_provider = source_status_provider
        try:
            self._migrate()
            os.chmod(self.path, 0o600)
            self.validate_storage()
        except StartupError:
            raise
        except (OSError, sqlite3.Error, TypeError, ValueError):
            raise StartupError("sound_event_storage_invalid") from None

    @contextmanager
    def _connection(self, *, write=False):
        connection = sqlite3.connect(self.path, timeout=5, isolation_level=None)
        connection.row_factory = sqlite3.Row
        try:
            connection.execute("BEGIN IMMEDIATE" if write else "BEGIN")
            yield connection
            connection.commit()
        except BaseException:
            connection.rollback()
            raise
        finally:
            connection.close()

    def _migrate(self):
        with self._connection(write=True) as connection:
            existing = {
                row["name"]
                for row in connection.execute(
                    "SELECT name FROM sqlite_master WHERE type='table' AND name LIKE 'sound_event_%'"
                )
            }
            legacy = {
                "sound_event_metadata",
                "sound_event_state",
                "sound_events",
                "sound_event_receipts",
            }
            required = legacy | {
                "sound_event_preferences",
                "sound_event_policy_receipts",
                "sound_event_feedback_receipts",
            }
            if existing and existing not in (legacy, required):
                raise ValueError("incomplete_schema")
            connection.executescript(
                """
                CREATE TABLE IF NOT EXISTS sound_event_metadata (
                  singleton INTEGER PRIMARY KEY CHECK(singleton=1),
                  version INTEGER NOT NULL CHECK(version=1));
                CREATE TABLE IF NOT EXISTS sound_event_state (
                  singleton INTEGER PRIMARY KEY CHECK(singleton=1),
                  revision INTEGER NOT NULL, event_count INTEGER NOT NULL,
                  authentication_tag TEXT NOT NULL);
                CREATE TABLE IF NOT EXISTS sound_events (
                  event_id TEXT PRIMARY KEY, core_id TEXT NOT NULL,
                  home_id TEXT NOT NULL, owner_id TEXT NOT NULL,
                  room_id TEXT NOT NULL, room_revision INTEGER NOT NULL,
                  device_id TEXT NOT NULL, device_revision INTEGER NOT NULL,
                  model_id TEXT NOT NULL, model_revision INTEGER NOT NULL,
                  provider_revision INTEGER NOT NULL, policy_revision INTEGER NOT NULL,
                  consent_revision INTEGER NOT NULL, class_name TEXT NOT NULL,
                  confidence REAL NOT NULL, observed_at_ms INTEGER NOT NULL,
                  evidence_digest TEXT NOT NULL, retention_expires_at_ms INTEGER NOT NULL,
                  automation_verified INTEGER NOT NULL, event_revision INTEGER NOT NULL,
                  acknowledged INTEGER NOT NULL, authentication_tag TEXT NOT NULL);
                CREATE INDEX IF NOT EXISTS sound_events_owner_time
                  ON sound_events(owner_id, observed_at_ms DESC);
                CREATE TABLE IF NOT EXISTS sound_event_receipts (
                  request_id TEXT PRIMARY KEY, owner_id TEXT NOT NULL,
                  family_id TEXT NOT NULL, command_digest TEXT NOT NULL,
                  receipt_json TEXT NOT NULL, authentication_tag TEXT NOT NULL,
                  created_at REAL NOT NULL);
                CREATE TABLE IF NOT EXISTS sound_event_preferences (
                  owner_id TEXT PRIMARY KEY, revision INTEGER NOT NULL,
                  notifications_enabled INTEGER NOT NULL,
                  bark_enabled INTEGER NOT NULL, noise_enabled INTEGER NOT NULL,
                  muted_until_ms INTEGER, raw_audio_retention TEXT NOT NULL,
                  authentication_tag TEXT NOT NULL);
                CREATE TABLE IF NOT EXISTS sound_event_policy_receipts (
                  request_id TEXT PRIMARY KEY, owner_id TEXT NOT NULL,
                  family_id TEXT NOT NULL, command_digest TEXT NOT NULL,
                  receipt_json TEXT NOT NULL, authentication_tag TEXT NOT NULL,
                  created_at REAL NOT NULL);
                CREATE TABLE IF NOT EXISTS sound_event_feedback_receipts (
                  request_id TEXT PRIMARY KEY, owner_id TEXT NOT NULL,
                  family_id TEXT NOT NULL, command_digest TEXT NOT NULL,
                  receipt_json TEXT NOT NULL, authentication_tag TEXT NOT NULL,
                  created_at REAL NOT NULL);
                """
            )
            columns = {
                row["name"]
                for row in connection.execute("PRAGMA table_info(sound_events)")
            }
            changed = False
            if "duration_ms" not in columns:
                connection.execute(
                    "ALTER TABLE sound_events ADD COLUMN duration_ms "
                    "INTEGER NOT NULL DEFAULT 1000"
                )
                changed = True
            if "feedback" not in columns:
                connection.execute("ALTER TABLE sound_events ADD COLUMN feedback TEXT")
                changed = True
            rows = connection.execute(
                "SELECT version FROM sound_event_metadata"
            ).fetchall()
            if not rows:
                connection.execute("INSERT INTO sound_event_metadata VALUES(1,1)")
            elif len(rows) != 1 or rows[0]["version"] != 1:
                raise ValueError("invalid_schema")
            rows = connection.execute("SELECT * FROM sound_event_state").fetchall()
            if not rows:
                connection.execute(
                    "INSERT INTO sound_event_state VALUES(1,1,0,?)",
                    (self._state_tag(1, 0),),
                )
            elif len(rows) != 1:
                raise ValueError("invalid_state")
            if changed:
                for row in connection.execute("SELECT * FROM sound_events").fetchall():
                    connection.execute(
                        "UPDATE sound_events SET authentication_tag=? WHERE event_id=?",
                        (self._event_tag(row), row["event_id"]),
                    )

    @staticmethod
    def _canonical(value):
        return json.dumps(
            value, sort_keys=True, separators=(",", ":"), allow_nan=False
        ).encode("utf-8")

    def _tag(self, domain, value):
        return hmac.new(
            self._key,
            b"larenor:sound-events:" + domain + b":v1\0" + self._canonical(value),
            hashlib.sha256,
        ).hexdigest()

    def _state_tag(self, revision, count):
        return self._tag(b"state", [revision, count])

    def _event_values(self, row):
        return [
            row[key]
            for key in (
                "event_id",
                "core_id",
                "home_id",
                "owner_id",
                "room_id",
                "room_revision",
                "device_id",
                "device_revision",
                "model_id",
                "model_revision",
                "provider_revision",
                "policy_revision",
                "consent_revision",
                "class_name",
                "confidence",
                "duration_ms",
                "observed_at_ms",
                "evidence_digest",
                "retention_expires_at_ms",
                "automation_verified",
                "event_revision",
                "acknowledged",
                "feedback",
            )
        ]

    def _event_tag(self, row):
        return self._tag(b"event", self._event_values(row))

    def _receipt_tag(self, owner, family, request, digest, receipt_json, created):
        return self._tag(
            b"receipt", [owner, family, request, digest, receipt_json, created]
        )

    def _preference_tag(self, row):
        return self._tag(
            b"preference",
            [
                row[key]
                for key in (
                    "owner_id",
                    "revision",
                    "notifications_enabled",
                    "bark_enabled",
                    "noise_enabled",
                    "muted_until_ms",
                    "raw_audio_retention",
                )
            ],
        )

    def _preference(self, connection, owner_id):
        row = connection.execute(
            "SELECT * FROM sound_event_preferences WHERE owner_id=?", (owner_id,)
        ).fetchone()
        if row is None:
            return SoundEventNotificationPolicy(
                schemaVersion=1,
                revision=1,
                notificationsEnabled=False,
                barkEnabled=True,
                noiseEnabled=True,
                mutedUntilMs=None,
                sourceClipRetention="never",
            )
        if not secrets.compare_digest(
            row["authentication_tag"], self._preference_tag(row)
        ):
            raise ValueError("invalid_preference")
        if (row["notifications_enabled"] not in (0, 1)
                or row["bark_enabled"] not in (0, 1)
                or row["noise_enabled"] not in (0, 1)):
            raise ValueError("invalid_preference")
        return SoundEventNotificationPolicy(
            schemaVersion=1,
            revision=row["revision"],
            notificationsEnabled=bool(row["notifications_enabled"]),
            barkEnabled=bool(row["bark_enabled"]),
            noiseEnabled=bool(row["noise_enabled"]),
            mutedUntilMs=row["muted_until_ms"],
            sourceClipRetention=row["raw_audio_retention"],
        )

    @staticmethod
    def _unavailable_source():
        return SoundSourceStatus(
            schemaVersion=1,
            state="unavailable",
            capabilityRevision=None,
            providerRevision=None,
            modelRevision=None,
            lastObservationAtMs=None,
            freshnessDeadlineMs=None,
            silenceProven=False,
            clipAvailable=False,
        )

    def _source_status(self, actor):
        if self._source_status_provider is None:
            return self._unavailable_source()
        try:
            return SoundSourceStatus.model_validate(
                self._source_status_provider(actor)
            )
        except Exception:
            return self._unavailable_source()

    @staticmethod
    def _foreign_request(connection, request_id, own_table):
        for table in (
            "sound_event_receipts",
            "sound_event_policy_receipts",
            "sound_event_feedback_receipts",
        ):
            if table != own_table and connection.execute(
                f"SELECT 1 FROM {table} WHERE request_id=?", (request_id,)
            ).fetchone():
                raise ApiError("revision_conflict", 409)

    def _state(self, connection):
        rows = connection.execute("SELECT * FROM sound_event_state").fetchall()
        if len(rows) != 1:
            raise ValueError("invalid_state")
        row = rows[0]
        if (
            row["singleton"] != 1
            or not 1 <= row["revision"] <= 2**63 - 1
            or not 0 <= row["event_count"] <= MAX_EVENTS
            or not secrets.compare_digest(
                row["authentication_tag"],
                self._state_tag(row["revision"], row["event_count"]),
            )
        ):
            raise ValueError("invalid_state")
        count = connection.execute("SELECT COUNT(*) FROM sound_events").fetchone()[0]
        if count != row["event_count"]:
            raise ValueError("invalid_count")
        return row

    def _set_state(self, connection, revision, count):
        connection.execute(
            "UPDATE sound_event_state SET revision=?,event_count=?,authentication_tag=? WHERE singleton=1",
            (revision, count, self._state_tag(revision, count)),
        )

    def _context_current(self, core_id, home_id):
        if (core_id, home_id) != (self._context.coreId, self._context.homeId):
            raise ApiError("not_found", 404)

    def _actor(self, actor):
        with self._primary.connection() as connection:
            self._auth.assert_current(connection, actor)
            row = connection.execute(
                "SELECT revision,role,disabled,must_change_password FROM users WHERE id=?",
                (actor.id,),
            ).fetchone()
        if (
            row is None
            or row["disabled"]
            or row["must_change_password"]
            or row["role"] != actor.role
        ):
            raise ApiError("forbidden", 403)
        return row["revision"]

    def _authority(self, actor, repository_revision):
        return SoundEventClientAuthority(
            schemaVersion=1,
            coreId=self._context.coreId,
            homeId=self._context.homeId,
            accountId=actor.id,
            sessionFamilyId=actor.family_id,
            accountRevision=self._actor(actor),
            repositoryRevision=repository_revision,
            canRead=True,
            canAcknowledge=True,
        )

    def record(self, authority, raw_event):
        """Trusted local classifier ingress. It never accepts raw audio."""
        authority = SoundEventAuthority.model_validate(authority)
        event = SoundEvent.model_validate(raw_event)
        self._context_current(authority.coreId, authority.homeId)
        if (
            (event.coreId, event.homeId) != (authority.coreId, authority.homeId)
            or event.roomId not in authority.accessibleRoomIds
            or event.deviceId not in authority.accessibleDeviceIds
            or not authority.active
            or not authority.canObserve
        ):
            raise ApiError("forbidden", 403)
        with self._primary.connection() as primary:
            user = primary.execute(
                "SELECT revision,disabled FROM users WHERE id=?", (authority.accountId,)
            ).fetchone()
            family = primary.execute(
                "SELECT revoked_at,expires_at FROM session_families WHERE id=? AND user_id=?",
                (authority.sessionFamilyId, authority.accountId),
            ).fetchone()
        if (
            user is None
            or user["disabled"]
            or user["revision"] != authority.accountRevision
            or family is None
            or family["revoked_at"] is not None
            or family["expires_at"] <= self._clock()
        ):
            raise ApiError("revision_conflict", 409)
        values = {
            "event_id": event.eventId,
            "core_id": event.coreId,
            "home_id": event.homeId,
            "owner_id": authority.accountId,
            "room_id": event.roomId,
            "room_revision": event.roomRevision,
            "device_id": event.deviceId,
            "device_revision": event.deviceRevision,
            "model_id": event.modelId,
            "model_revision": event.modelRevision,
            "provider_revision": event.providerRevision,
            "policy_revision": event.policyRevision,
            "consent_revision": event.consentRevision,
            "class_name": event.className,
            "confidence": event.confidence,
            "duration_ms": event.durationMs,
            "observed_at_ms": event.observedAtMs,
            "evidence_digest": event.evidenceDigest,
            "retention_expires_at_ms": event.retentionExpiresAtMs,
            "automation_verified": int(event.automationVerified),
            "event_revision": 1,
            "acknowledged": 0,
            "feedback": None,
        }
        tag = self._event_tag(values)
        try:
            with self._connection(write=True) as connection:
                state = self._state(connection)
                old = connection.execute(
                    "SELECT * FROM sound_events WHERE event_id=?", (event.eventId,)
                ).fetchone()
                if old is not None:
                    if not secrets.compare_digest(
                        old["authentication_tag"], self._event_tag(old)
                    ):
                        raise ValueError("invalid_event")
                    if self._event_values(old) != self._event_values(values):
                        raise ApiError("invalid_request")
                    return
                if state["event_count"] >= MAX_EVENTS:
                    raise ApiError("rate_limited", 429)
                columns = ",".join(values)
                placeholders = ",".join("?" for _ in values)
                connection.execute(
                    f"INSERT INTO sound_events({columns},authentication_tag) VALUES({placeholders},?)",
                    (*values.values(), tag),
                )
                self._set_state(
                    connection, state["revision"] + 1, state["event_count"] + 1
                )
        except ApiError:
            raise
        except (sqlite3.Error, TypeError, ValueError, OverflowError):
            raise ApiError("sound_event_integrity_failed", 503) from None

    def _record(self, row, policy=None, now_ms=0):
        if not secrets.compare_digest(row["authentication_tag"], self._event_tag(row)):
            raise ValueError("invalid_event")
        eligible = False
        if policy is not None:
            class_enabled = (
                policy.barkEnabled if row["class_name"] == "bark"
                else policy.noiseEnabled
            )
            eligible = (
                policy.notificationsEnabled
                and class_enabled
                and (policy.mutedUntilMs is None or policy.mutedUntilMs <= now_ms)
                and not row["acknowledged"]
                and row["feedback"] != "false_alarm"
            )
        return SoundEventRecord(
            schemaVersion=1,
            eventId=row["event_id"],
            roomId=row["room_id"],
            deviceId=row["device_id"],
            className=row["class_name"],
            confidence=row["confidence"],
            durationMs=row["duration_ms"],
            observedAtMs=row["observed_at_ms"],
            retentionExpiresAtMs=row["retention_expires_at_ms"],
            eventRevision=row["event_revision"],
            acknowledged=bool(row["acknowledged"]),
            automationVerified=bool(row["automation_verified"]),
            feedback=row["feedback"],
            notificationEligible=eligible,
        )

    def list(
        self,
        actor,
        core_id,
        home_id,
        *,
        room_id=None,
        class_name=None,
        acknowledged=None,
        limit=100,
    ):
        self._context_current(core_id, home_id)
        try:
            with self._connection() as connection:
                state = self._state(connection)
                authority = self._authority(actor, state["revision"])
                policy = self._preference(connection, actor.id)
                rows = connection.execute(
                    "SELECT * FROM sound_events WHERE owner_id=? ORDER BY observed_at_ms DESC LIMIT ?",
                    (actor.id, MAX_EVENTS + 1),
                ).fetchall()
                if len(rows) > MAX_EVENTS:
                    raise ValueError("too_many_events")
                now_ms = int(self._clock() * 1000)
                events = []
                for row in rows:
                    value = self._record(row, policy, now_ms)
                    if value.retentionExpiresAtMs <= now_ms:
                        continue
                    if room_id is not None and value.roomId != room_id:
                        continue
                    if class_name is not None and value.className != class_name:
                        continue
                    if acknowledged is not None and value.acknowledged != acknowledged:
                        continue
                    events.append(value)
                    if len(events) == limit:
                        break
                return SoundEventSnapshot(
                    schemaVersion=2,
                    authority=authority,
                    repositoryRevision=state["revision"],
                    policy=policy,
                    sourceStatus=self._source_status(actor),
                    events=events,
                )
        except ApiError:
            raise
        except (sqlite3.Error, TypeError, ValueError, OverflowError):
            raise ApiError("sound_event_integrity_failed", 503) from None

    def acknowledge(self, actor, core_id, home_id, event_id, raw_request):
        self._context_current(core_id, home_id)
        request = SoundEventAcknowledgementRequest.model_validate(raw_request)
        self._actor(actor)
        digest = hashlib.sha256(
            b"sound-event-ack-v1\0" + self._canonical(request.model_dump(mode="json"))
        ).hexdigest()
        try:
            with self._connection(write=True) as connection:
                state = self._state(connection)
                self._foreign_request(
                    connection, request.requestId, "sound_event_receipts"
                )
                replay = connection.execute(
                    "SELECT * FROM sound_event_receipts WHERE request_id=?",
                    (request.requestId,),
                ).fetchone()
                if replay is not None:
                    expected = self._receipt_tag(
                        replay["owner_id"],
                        replay["family_id"],
                        replay["request_id"],
                        replay["command_digest"],
                        replay["receipt_json"],
                        replay["created_at"],
                    )
                    if not secrets.compare_digest(
                        replay["authentication_tag"], expected
                    ):
                        raise ValueError("invalid_receipt")
                    if (
                        replay["owner_id"] != actor.id
                        or replay["family_id"] != actor.family_id
                        or not secrets.compare_digest(replay["command_digest"], digest)
                    ):
                        raise ApiError("revision_conflict", 409)
                    return SoundEventAcknowledgement.model_validate_json(
                        replay["receipt_json"]
                    )
                row = connection.execute(
                    "SELECT * FROM sound_events WHERE event_id=? AND owner_id=?",
                    (event_id, actor.id),
                ).fetchone()
                if row is None:
                    raise ApiError("not_found", 404)
                self._record(row)
                if (
                    state["revision"] != request.expectedRepositoryRevision
                    or row["event_revision"] != request.expectedEventRevision
                    or row["acknowledged"]
                ):
                    raise ApiError("revision_conflict", 409)
                event_revision = row["event_revision"] + 1
                repository_revision = state["revision"] + 1
                values = dict(row)
                values["event_revision"] = event_revision
                values["acknowledged"] = 1
                connection.execute(
                    "UPDATE sound_events SET event_revision=?,acknowledged=1,authentication_tag=? WHERE event_id=?",
                    (event_revision, self._event_tag(values), event_id),
                )
                self._set_state(connection, repository_revision, state["event_count"])
                receipt = SoundEventAcknowledgement(
                    schemaVersion=1,
                    requestId=request.requestId,
                    eventId=event_id,
                    coreId=core_id,
                    homeId=home_id,
                    accountId=actor.id,
                    sessionFamilyId=actor.family_id,
                    repositoryRevision=repository_revision,
                    eventRevision=event_revision,
                    acknowledged=True,
                )
                receipt_json = receipt.model_dump_json()
                created = self._clock()
                connection.execute(
                    "INSERT INTO sound_event_receipts VALUES(?,?,?,?,?,?,?)",
                    (
                        request.requestId,
                        actor.id,
                        actor.family_id,
                        digest,
                        receipt_json,
                        self._receipt_tag(
                            actor.id,
                            actor.family_id,
                            request.requestId,
                            digest,
                            receipt_json,
                            created,
                        ),
                        created,
                    ),
                )
                connection.execute(
                    "DELETE FROM sound_event_receipts WHERE request_id IN "
                    "(SELECT request_id FROM sound_event_receipts ORDER BY created_at DESC LIMIT -1 OFFSET ?)",
                    (MAX_RECEIPTS,),
                )
                return receipt
        except ApiError:
            raise
        except (sqlite3.Error, TypeError, ValueError, OverflowError):
            raise ApiError("sound_event_integrity_failed", 503) from None

    def update_policy(self, actor, core_id, home_id, raw_request):
        self._context_current(core_id, home_id)
        request = SoundEventPolicyRequest.model_validate(raw_request)
        self._actor(actor)
        now_ms = int(self._clock() * 1000)
        if (request.mutedUntilMs is not None
                and (request.mutedUntilMs <= now_ms
                     or request.mutedUntilMs > now_ms + 7 * 24 * 60 * 60 * 1000)):
            raise ApiError("invalid_request")
        digest = hashlib.sha256(
            b"sound-event-policy-v1\0"
            + self._canonical(request.model_dump(mode="json"))
        ).hexdigest()
        try:
            with self._connection(write=True) as connection:
                state = self._state(connection)
                self._foreign_request(
                    connection, request.requestId, "sound_event_policy_receipts"
                )
                replay = connection.execute(
                    "SELECT * FROM sound_event_policy_receipts WHERE request_id=?",
                    (request.requestId,),
                ).fetchone()
                if replay is not None:
                    expected = self._receipt_tag(
                        replay["owner_id"], replay["family_id"],
                        replay["request_id"], replay["command_digest"],
                        replay["receipt_json"], replay["created_at"],
                    )
                    if (not secrets.compare_digest(
                            replay["authentication_tag"], expected)
                            or replay["owner_id"] != actor.id
                            or replay["family_id"] != actor.family_id
                            or not secrets.compare_digest(
                                replay["command_digest"], digest)):
                        raise ApiError("revision_conflict", 409)
                    return SoundEventPolicyReceipt.model_validate_json(
                        replay["receipt_json"]
                    )
                current = self._preference(connection, actor.id)
                if (state["revision"] != request.expectedRepositoryRevision
                        or current.revision != request.expectedPolicyRevision):
                    raise ApiError("revision_conflict", 409)
                policy = SoundEventNotificationPolicy(
                    schemaVersion=1,
                    revision=current.revision + 1,
                    notificationsEnabled=request.notificationsEnabled,
                    barkEnabled=request.barkEnabled,
                    noiseEnabled=request.noiseEnabled,
                    mutedUntilMs=request.mutedUntilMs,
                    sourceClipRetention=request.sourceClipRetention,
                )
                values = {
                    "owner_id": actor.id,
                    "revision": policy.revision,
                    "notifications_enabled": int(policy.notificationsEnabled),
                    "bark_enabled": int(policy.barkEnabled),
                    "noise_enabled": int(policy.noiseEnabled),
                    "muted_until_ms": policy.mutedUntilMs,
                    "raw_audio_retention": policy.sourceClipRetention,
                }
                connection.execute(
                    "INSERT INTO sound_event_preferences VALUES(?,?,?,?,?,?,?,?) "
                    "ON CONFLICT(owner_id) DO UPDATE SET "
                    "revision=excluded.revision,"
                    "notifications_enabled=excluded.notifications_enabled,"
                    "bark_enabled=excluded.bark_enabled,"
                    "noise_enabled=excluded.noise_enabled,"
                    "muted_until_ms=excluded.muted_until_ms,"
                    "raw_audio_retention=excluded.raw_audio_retention,"
                    "authentication_tag=excluded.authentication_tag",
                    (*values.values(), self._preference_tag(values)),
                )
                repository_revision = state["revision"] + 1
                self._set_state(
                    connection, repository_revision, state["event_count"]
                )
                receipt = SoundEventPolicyReceipt(
                    schemaVersion=1,
                    requestId=request.requestId,
                    accountId=actor.id,
                    sessionFamilyId=actor.family_id,
                    repositoryRevision=repository_revision,
                    policy=policy,
                )
                receipt_json = receipt.model_dump_json()
                created = self._clock()
                connection.execute(
                    "INSERT INTO sound_event_policy_receipts VALUES(?,?,?,?,?,?,?)",
                    (
                        request.requestId, actor.id, actor.family_id, digest,
                        receipt_json,
                        self._receipt_tag(
                            actor.id, actor.family_id, request.requestId,
                            digest, receipt_json, created,
                        ),
                        created,
                    ),
                )
                self._trim_receipts(connection, "sound_event_policy_receipts")
                return receipt
        except ApiError:
            raise
        except (sqlite3.Error, TypeError, ValueError, OverflowError):
            raise ApiError("sound_event_integrity_failed", 503) from None

    def feedback(self, actor, core_id, home_id, event_id, raw_request):
        self._context_current(core_id, home_id)
        request = SoundEventFeedbackRequest.model_validate(raw_request)
        self._actor(actor)
        digest = hashlib.sha256(
            b"sound-event-feedback-v1\0"
            + self._canonical(request.model_dump(mode="json"))
        ).hexdigest()
        try:
            with self._connection(write=True) as connection:
                state = self._state(connection)
                self._foreign_request(
                    connection, request.requestId, "sound_event_feedback_receipts"
                )
                replay = connection.execute(
                    "SELECT * FROM sound_event_feedback_receipts WHERE request_id=?",
                    (request.requestId,),
                ).fetchone()
                if replay is not None:
                    expected = self._receipt_tag(
                        replay["owner_id"], replay["family_id"],
                        replay["request_id"], replay["command_digest"],
                        replay["receipt_json"], replay["created_at"],
                    )
                    if (not secrets.compare_digest(
                            replay["authentication_tag"], expected)
                            or replay["owner_id"] != actor.id
                            or replay["family_id"] != actor.family_id
                            or not secrets.compare_digest(
                                replay["command_digest"], digest)):
                        raise ApiError("revision_conflict", 409)
                    return SoundEventFeedbackReceipt.model_validate_json(
                        replay["receipt_json"]
                    )
                row = connection.execute(
                    "SELECT * FROM sound_events WHERE event_id=? AND owner_id=?",
                    (event_id, actor.id),
                ).fetchone()
                if row is None:
                    raise ApiError("not_found", 404)
                self._record(row)
                if (state["revision"] != request.expectedRepositoryRevision
                        or row["event_revision"] != request.expectedEventRevision):
                    raise ApiError("revision_conflict", 409)
                event_revision = row["event_revision"] + 1
                repository_revision = state["revision"] + 1
                values = dict(row)
                values["event_revision"] = event_revision
                values["feedback"] = request.classification
                connection.execute(
                    "UPDATE sound_events SET event_revision=?,feedback=?,"
                    "authentication_tag=? WHERE event_id=?",
                    (
                        event_revision, request.classification,
                        self._event_tag(values), event_id,
                    ),
                )
                self._set_state(
                    connection, repository_revision, state["event_count"]
                )
                receipt = SoundEventFeedbackReceipt(
                    schemaVersion=1,
                    requestId=request.requestId,
                    eventId=event_id,
                    accountId=actor.id,
                    sessionFamilyId=actor.family_id,
                    repositoryRevision=repository_revision,
                    eventRevision=event_revision,
                    classification=request.classification,
                )
                receipt_json = receipt.model_dump_json()
                created = self._clock()
                connection.execute(
                    "INSERT INTO sound_event_feedback_receipts VALUES(?,?,?,?,?,?,?)",
                    (
                        request.requestId, actor.id, actor.family_id, digest,
                        receipt_json,
                        self._receipt_tag(
                            actor.id, actor.family_id, request.requestId,
                            digest, receipt_json, created,
                        ),
                        created,
                    ),
                )
                self._trim_receipts(connection, "sound_event_feedback_receipts")
                return receipt
        except ApiError:
            raise
        except (sqlite3.Error, TypeError, ValueError, OverflowError):
            raise ApiError("sound_event_integrity_failed", 503) from None

    @staticmethod
    def _trim_receipts(connection, table):
        connection.execute(
            f"DELETE FROM {table} WHERE request_id IN "
            f"(SELECT request_id FROM {table} ORDER BY created_at DESC "
            "LIMIT -1 OFFSET ?)",
            (MAX_RECEIPTS,),
        )

    def validate_storage(self):
        try:
            with self._connection() as connection:
                self._state(connection)
                events = connection.execute(
                    "SELECT * FROM sound_events LIMIT ?", (MAX_EVENTS + 1,)
                ).fetchall()
                if len(events) > MAX_EVENTS:
                    raise ValueError("too_many_events")
                for row in events:
                    self._record(row)
                receipts = connection.execute(
                    "SELECT * FROM sound_event_receipts LIMIT ?", (MAX_RECEIPTS + 1,)
                ).fetchall()
                if len(receipts) > MAX_RECEIPTS:
                    raise ValueError("too_many_receipts")
                for row in receipts:
                    expected = self._receipt_tag(
                        row["owner_id"],
                        row["family_id"],
                        row["request_id"],
                        row["command_digest"],
                        row["receipt_json"],
                        row["created_at"],
                    )
                    if not secrets.compare_digest(row["authentication_tag"], expected):
                        raise ValueError("invalid_receipt")
                    SoundEventAcknowledgement.model_validate_json(
                        row["receipt_json"]
                    )
                preferences = connection.execute(
                    "SELECT * FROM sound_event_preferences LIMIT ?",
                    (MAX_PREFERENCES + 1,),
                ).fetchall()
                if len(preferences) > MAX_PREFERENCES:
                    raise ValueError("too_many_preferences")
                for row in preferences:
                    self._preference(connection, row["owner_id"])
                for table, model in (
                    ("sound_event_policy_receipts", SoundEventPolicyReceipt),
                    ("sound_event_feedback_receipts", SoundEventFeedbackReceipt),
                ):
                    rows = connection.execute(
                        f"SELECT * FROM {table} LIMIT ?", (MAX_RECEIPTS + 1,)
                    ).fetchall()
                    if len(rows) > MAX_RECEIPTS:
                        raise ValueError("too_many_receipts")
                    for row in rows:
                        expected = self._receipt_tag(
                            row["owner_id"], row["family_id"],
                            row["request_id"], row["command_digest"],
                            row["receipt_json"], row["created_at"],
                        )
                        if not secrets.compare_digest(
                            row["authentication_tag"], expected
                        ):
                            raise ValueError("invalid_receipt")
                        model.model_validate_json(row["receipt_json"])
        except (sqlite3.Error, TypeError, ValueError, OverflowError):
            raise StartupError("sound_event_storage_invalid") from None
