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
from ..local_notifications.models import CreateNotification, Notification
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
MAX_NOTIFICATION_DISPATCH = 256


class SoundEventRepository:
    """Stores classification metadata only; audio bytes and locations have no column."""

    def __init__(
        self, path, key, primary_db, auth, context, clock,
        source_status_provider=None, source_access_provider=None,
        notification_writer=None,
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
        if source_access_provider is not None and not callable(source_access_provider):
            raise ValueError("invalid_source_access_provider")
        self._source_access_provider = source_access_provider
        if notification_writer is not None and not callable(
            getattr(notification_writer, "append_internal", None)
        ):
            raise ValueError("invalid_notification_writer")
        self._notification_writer = notification_writer
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
            previous = legacy | {
                "sound_event_preferences",
                "sound_event_policy_receipts",
                "sound_event_feedback_receipts",
            }
            required = previous | {"sound_event_notification_outbox"}
            if existing and existing not in (legacy, previous, required):
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
                CREATE TABLE IF NOT EXISTS sound_event_notification_outbox (
                  event_id TEXT PRIMARY KEY, owner_id TEXT NOT NULL,
                  family_id TEXT NOT NULL, source_revision INTEGER NOT NULL,
                  consent_revision INTEGER NOT NULL,
                  state TEXT NOT NULL CHECK(state IN ('pending','delivered','cancelled')),
                  notification_id TEXT, notification_sequence INTEGER,
                  authentication_tag TEXT NOT NULL);
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

    @staticmethod
    def _same_ingress(row, values):
        if values["automation_verified"] and not row["automation_verified"]:
            return False
        mutable = {
            "automation_verified", "event_revision", "acknowledged", "feedback"
        }
        return all(row[key] == value for key, value in values.items() if key not in mutable)

    def _outbox_tag(self, row):
        return self._tag(
            b"notification-outbox",
            [
                row[key]
                for key in (
                    "event_id", "owner_id", "family_id", "source_revision",
                    "consent_revision", "state", "notification_id",
                    "notification_sequence",
                )
            ],
        )

    def _outbox(self, row):
        if (
            row is None
            or row["state"] not in {"pending", "delivered", "cancelled"}
            or type(row["source_revision"]) is not int
            or not 1 <= row["source_revision"] < 2**63
            or type(row["consent_revision"]) is not int
            or not 1 <= row["consent_revision"] < 2**63
            or (row["state"] == "delivered")
            != (row["notification_id"] is not None)
            or (row["state"] == "delivered")
            != (row["notification_sequence"] is not None)
            or row["notification_sequence"] is not None
            and (
                type(row["notification_sequence"]) is not int
                or not 1 <= row["notification_sequence"] < 2**63
            )
            or not secrets.compare_digest(
                row["authentication_tag"], self._outbox_tag(row)
            )
        ):
            raise ValueError("invalid_notification_outbox")
        return row

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
    def _notification_eligible(row, policy, now_ms):
        class_enabled = (
            policy.barkEnabled
            if row["class_name"] == "bark"
            else policy.noiseEnabled
        )
        return (
            policy.notificationsEnabled
            and class_enabled
            and (policy.mutedUntilMs is None or policy.mutedUntilMs <= now_ms)
            and not row["acknowledged"]
            and row["feedback"] != "false_alarm"
            and row["retention_expires_at_ms"] > now_ms
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
        except ApiError:
            raise
        except Exception:
            return self._unavailable_source()

    def _source_access(self, actor):
        if self._source_access_provider is None:
            return None
        value = self._source_access_provider(actor)
        if value not in (None, False, True):
            raise ValueError("invalid_source_access")
        return value

    def _require_source_access(self, actor):
        access = self._source_access(actor)
        if access is False:
            raise ApiError("forbidden", 403)
        status = self._source_status(actor)
        if access is not None and status.state == "unavailable":
            raise ApiError("forbidden", 403)
        return status

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
        return bool(self.record_batch(authority, [raw_event]))

    def record_batch(self, authority, raw_events, *, cancelled=lambda: False):
        """Atomically store a bounded provider batch after its full read completes."""
        authority = SoundEventAuthority.model_validate(authority)
        if (not callable(cancelled) or type(raw_events) is not list
                or not 1 <= len(raw_events) <= 256):
            raise ApiError("invalid_request")
        events = [SoundEvent.model_validate(raw) for raw in raw_events]
        if len({event.eventId for event in events}) != len(events):
            raise ApiError("invalid_request")
        self._context_current(authority.coreId, authority.homeId)
        if (not authority.active or not authority.canObserve or any(
                (event.coreId, event.homeId) != (authority.coreId, authority.homeId)
                or event.roomId not in authority.accessibleRoomIds
                or event.deviceId not in authority.accessibleDeviceIds
                for event in events)):
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
        values_list = [{
            "event_id": event.eventId, "core_id": event.coreId,
            "home_id": event.homeId, "owner_id": authority.accountId,
            "room_id": event.roomId, "room_revision": event.roomRevision,
            "device_id": event.deviceId, "device_revision": event.deviceRevision,
            "model_id": event.modelId, "model_revision": event.modelRevision,
            "provider_revision": event.providerRevision,
            "policy_revision": event.policyRevision,
            "consent_revision": event.consentRevision,
            "class_name": event.className, "confidence": event.confidence,
            "duration_ms": event.durationMs, "observed_at_ms": event.observedAtMs,
            "evidence_digest": event.evidenceDigest,
            "retention_expires_at_ms": event.retentionExpiresAtMs,
            "automation_verified": int(event.automationVerified),
            "event_revision": 1, "acknowledged": 0, "feedback": None,
        } for event in events]
        try:
            if cancelled():
                raise ApiError("revision_conflict", 409)
            with self._connection(write=True) as connection:
                state = self._state(connection)
                policy = self._preference(connection, authority.accountId)
                now_ms = int(self._clock() * 1000)
                inserted = 0
                for values in values_list:
                    old = connection.execute(
                        "SELECT * FROM sound_events WHERE event_id=?", (values["event_id"],)
                    ).fetchone()
                    if old is not None:
                        if not secrets.compare_digest(old["authentication_tag"], self._event_tag(old)):
                            raise ValueError("invalid_event")
                        if not self._same_ingress(old, values):
                            raise ApiError("invalid_request")
                        continue
                    if state["event_count"] + inserted >= MAX_EVENTS:
                        raise ApiError("rate_limited", 429)
                    columns = ",".join(values)
                    placeholders = ",".join("?" for _ in values)
                    connection.execute(
                        f"INSERT INTO sound_events({columns},authentication_tag) VALUES({placeholders},?)",
                        (*values.values(), self._event_tag(values)),
                    )
                    if (
                        self._notification_writer is not None
                        and not values["automation_verified"]
                        and self._notification_eligible(values, policy, now_ms)
                    ):
                        outbox = {
                            "event_id": values["event_id"],
                            "owner_id": authority.accountId,
                            "family_id": authority.sessionFamilyId,
                            "source_revision": values["policy_revision"],
                            "consent_revision": values["consent_revision"],
                            "state": "pending",
                            "notification_id": None,
                            "notification_sequence": None,
                        }
                        connection.execute(
                            "INSERT INTO sound_event_notification_outbox VALUES(?,?,?,?,?,?,?,?,?)",
                            (*outbox.values(), self._outbox_tag(outbox)),
                        )
                    inserted += 1
                if cancelled():
                    raise ApiError("revision_conflict", 409)
                if inserted:
                    self._set_state(
                        connection, state["revision"] + 1,
                        state["event_count"] + inserted,
                    )
                return inserted
        except ApiError:
            raise
        except (sqlite3.Error, TypeError, ValueError, OverflowError):
            raise ApiError("sound_event_integrity_failed", 503) from None

    @staticmethod
    def _notification_request(row):
        title = "Bark detected" if row["class_name"] == "bark" else "Sound detected"
        return CreateNotification(
            schemaVersion=1,
            recipientUserId=row["owner_id"],
            idempotencyKey="sound-event:" + row["event_id"],
            category="sound_event",
            sensitivity="private",
            title=title,
            body="A configured camera reported a sound event.",
            target="/sound-events/" + row["event_id"],
        )

    def _set_outbox_state(
        self, connection, row, state, *, notification_id=None,
        notification_sequence=None,
    ):
        values = dict(row)
        values.update(
            state=state,
            notification_id=notification_id,
            notification_sequence=notification_sequence,
        )
        connection.execute(
            "UPDATE sound_event_notification_outbox SET state=?,notification_id=?,"
            "notification_sequence=?,authentication_tag=? WHERE event_id=?",
            (
                state, notification_id, notification_sequence,
                self._outbox_tag(values), row["event_id"],
            ),
        )

    def _mark_notification_delivered(self, connection, outbox, event, notification):
        notification = Notification.model_validate(notification)
        request = self._notification_request(event)
        if (
            notification.category != request.category
            or notification.sensitivity != request.sensitivity
            or notification.title != request.title
            or notification.body != request.body
            or notification.target != request.target
        ):
            raise ValueError("invalid_notification_receipt")
        self._set_outbox_state(
            connection,
            outbox,
            "delivered",
            notification_id=notification.id,
            notification_sequence=notification.sequence,
        )
        if not event["automation_verified"]:
            state = self._state(connection)
            values = dict(event)
            values["automation_verified"] = 1
            values["event_revision"] += 1
            connection.execute(
                "UPDATE sound_events SET automation_verified=1,event_revision=?,"
                "authentication_tag=? WHERE event_id=?",
                (
                    values["event_revision"], self._event_tag(values),
                    event["event_id"],
                ),
            )
            self._set_state(
                connection, state["revision"] + 1, state["event_count"]
            )

    def dispatch_notifications(
        self,
        actor,
        *,
        source_revision,
        consent_revision,
        assert_current,
        cancelled=lambda: False,
    ):
        """Append pending F45 notifications to F54 with idempotent receipts."""
        if self._notification_writer is None:
            return 0
        if (
            type(source_revision) is not int
            or not 1 <= source_revision < 2**63
            or type(consent_revision) is not int
            or not 1 <= consent_revision < 2**63
            or not callable(assert_current)
            or not callable(cancelled)
        ):
            raise ApiError("invalid_request")
        account_revision = self._actor(actor)
        assert_current()
        try:
            with self._connection() as connection:
                candidates = connection.execute(
                    "SELECT event_id FROM sound_event_notification_outbox "
                    "WHERE owner_id=? AND state='pending' ORDER BY event_id LIMIT ?",
                    (actor.id, MAX_NOTIFICATION_DISPATCH),
                ).fetchall()
            delivered = 0
            for candidate in candidates:
                if cancelled():
                    raise ApiError("revision_conflict", 409)
                with self._connection(write=True) as connection:
                    outbox = self._outbox(connection.execute(
                        "SELECT * FROM sound_event_notification_outbox WHERE event_id=?",
                        (candidate["event_id"],),
                    ).fetchone())
                    if outbox["state"] != "pending":
                        continue
                    event = connection.execute(
                        "SELECT * FROM sound_events WHERE event_id=? AND owner_id=?",
                        (outbox["event_id"], actor.id),
                    ).fetchone()
                    if event is None:
                        raise ValueError("orphan_notification_outbox")
                    self._record(event)
                    policy = self._preference(connection, actor.id)
                    now_ms = int(self._clock() * 1000)
                    stale = (
                        outbox["family_id"] != actor.family_id
                        or outbox["source_revision"] != source_revision
                        or outbox["consent_revision"] != consent_revision
                        or event["policy_revision"] != source_revision
                        or event["consent_revision"] != consent_revision
                        or not self._notification_eligible(event, policy, now_ms)
                    )
                    if stale:
                        self._set_outbox_state(connection, outbox, "cancelled")
                        continue
                    assert_current()
                    current_revision = self._actor(actor)
                    if current_revision != account_revision:
                        raise ApiError("revision_conflict", 409)
                    request = self._notification_request(event)
                    with self._primary.transaction() as primary:
                        self._auth.assert_current(primary, actor)
                        user = primary.execute(
                            "SELECT revision,disabled,must_change_password FROM users "
                            "WHERE id=?", (actor.id,),
                        ).fetchone()
                        if (
                            user is None
                            or user["disabled"]
                            or user["must_change_password"]
                            or user["revision"] != account_revision
                        ):
                            raise ApiError("revision_conflict", 409)
                        receipt = self._notification_writer.append_internal(
                            primary, request
                        )
                        self._auth.assert_current(primary, actor)
                        current = primary.execute(
                            "SELECT revision,disabled,must_change_password FROM users "
                            "WHERE id=?", (actor.id,),
                        ).fetchone()
                        if (
                            current is None
                            or current["disabled"]
                            or current["must_change_password"]
                            or current["revision"] != account_revision
                        ):
                            raise ApiError("revision_conflict", 409)
                        if cancelled():
                            raise ApiError("revision_conflict", 409)
                        assert_current(primary)
                    assert_current()
                    if cancelled():
                        raise ApiError("revision_conflict", 409)
                    self._mark_notification_delivered(
                        connection, outbox, event, receipt["notification"]
                    )
                    delivered += 1
            assert_current()
            return delivered
        except ApiError:
            raise
        except (sqlite3.Error, TypeError, ValueError, OverflowError):
            raise ApiError("sound_event_integrity_failed", 503) from None

    def purge_expired(self, actor, now_ms):
        """Delete only this actor's expired metadata and preserve sealed state."""
        self._actor(actor)
        if type(now_ms) is not int or not 0 <= now_ms <= 2**63 - 1:
            raise ApiError("invalid_request")
        try:
            with self._connection(write=True) as connection:
                state = self._state(connection)
                rows = connection.execute(
                    "SELECT * FROM sound_events WHERE owner_id=? AND retention_expires_at_ms<=?",
                    (actor.id, now_ms),
                ).fetchall()
                for row in rows:
                    self._record(row)
                if rows:
                    connection.executemany(
                        "DELETE FROM sound_event_notification_outbox WHERE event_id=?",
                        [(row["event_id"],) for row in rows],
                    )
                    connection.executemany(
                        "DELETE FROM sound_events WHERE event_id=?",
                        [(row["event_id"],) for row in rows],
                    )
                    self._set_state(
                        connection,
                        state["revision"] + 1,
                        state["event_count"] - len(rows),
                    )
                return len(rows)
        except ApiError:
            raise
        except (sqlite3.Error, TypeError, ValueError, OverflowError):
            raise ApiError("sound_event_integrity_failed", 503) from None

    def _record(self, row, policy=None, now_ms=0):
        if not secrets.compare_digest(row["authentication_tag"], self._event_tag(row)):
            raise ValueError("invalid_event")
        eligible = False
        if policy is not None:
            eligible = self._notification_eligible(row, policy, now_ms)
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
        source_access = self._source_access(actor)
        source_status = self._source_status(actor)
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
                    if (source_access is False
                            or source_access is not None and source_status.state == "unavailable"):
                        break
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
                    sourceStatus=source_status,
                    events=events,
                )
        except ApiError:
            raise
        except (sqlite3.Error, TypeError, ValueError, OverflowError):
            raise ApiError("sound_event_integrity_failed", 503) from None

    def acknowledge(self, actor, core_id, home_id, event_id, raw_request):
        self._context_current(core_id, home_id)
        self._require_source_access(actor)
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
                outbox = connection.execute(
                    "SELECT * FROM sound_event_notification_outbox WHERE event_id=?",
                    (event_id,),
                ).fetchone()
                if outbox is not None:
                    outbox = self._outbox(outbox)
                    if outbox["state"] == "pending":
                        self._set_outbox_state(connection, outbox, "cancelled")
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
        self._require_source_access(actor)
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
                outbox = connection.execute(
                    "SELECT * FROM sound_event_notification_outbox WHERE event_id=?",
                    (event_id,),
                ).fetchone()
                if outbox is not None:
                    outbox = self._outbox(outbox)
                    if (
                        outbox["state"] == "pending"
                        and request.classification == "false_alarm"
                    ):
                        self._set_outbox_state(connection, outbox, "cancelled")
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
                outbox = connection.execute(
                    "SELECT * FROM sound_event_notification_outbox LIMIT ?",
                    (MAX_EVENTS + 1,),
                ).fetchall()
                if len(outbox) > MAX_EVENTS:
                    raise ValueError("too_many_notification_outbox_rows")
                event_ids = {row["event_id"] for row in events}
                for row in outbox:
                    self._outbox(row)
                    if row["event_id"] not in event_ids:
                        raise ValueError("orphan_notification_outbox")
        except (sqlite3.Error, TypeError, ValueError, OverflowError):
            raise StartupError("sound_event_storage_invalid") from None
