import hashlib
import hmac
import json
import math
import re
import secrets
import sqlite3
import uuid

from cryptography.exceptions import InvalidTag
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

from ..errors import ApiError, StartupError
from ..home_resources.models import HomeScope
from . import schema
from .models import (
    AcknowledgeNotifications,
    CreateNotification,
    RegisterSubscription,
    UpdateSubscription,
)

_IDENTITY = re.compile(r"^[0-9a-f]{32}$")
_DIGEST = re.compile(r"^[0-9a-f]{64}$")


class LocalNotificationService:
    """Persistent pull inbox. This class deliberately has no transport dependency."""

    def __init__(self, db, auth, settings, key, context):
        self.db, self.auth, self.settings, self._key = db, auth, settings, key
        self.scope = HomeScope.model_validate(context.model_dump())
        self._cipher = AESGCM(key)

    def _scope(self, core_id, home_id):
        if (core_id, home_id) != (self.scope.coreId, self.scope.homeId):
            raise ApiError("not_found", 404)

    def _subscription_tag(self, row):
        payload = json.dumps([
            self.scope.coreId, self.scope.homeId, row["id"], row["owner_id"],
            row["family_id"], row["revision"], row["permission"], row["state"],
            row["expires_at"], row["created_at"],
        ], separators=(",", ":"), allow_nan=False).encode("ascii")
        return hmac.new(self._key, b"larenor-local-notification-subscription-v1\0" + payload,
                        hashlib.sha256).hexdigest()

    def _event_tag(self, recipient_id, key, body):
        payload = json.dumps([self.scope.coreId, self.scope.homeId, recipient_id, key, body],
                             sort_keys=True, separators=(",", ":"), ensure_ascii=False,
                             allow_nan=False).encode("utf-8")
        return hmac.new(self._key, b"larenor-local-notification-event-v1\0" + payload,
                        hashlib.sha256).hexdigest()

    def _event_aad(self, row):
        return (f"larenor-local-notification-v1:{self.scope.coreId}:{self.scope.homeId}:"
                f"{row['sequence']}:{row['id']}:{row['recipient_id']}:{row['idempotency_key']}:"
                f"{row['envelope_tag']}:{row['created_at']}").encode("ascii")

    @staticmethod
    def _finite(value):
        return type(value) is float and math.isfinite(value)

    def _validate_subscription(self, row):
        if (row is None or any(not isinstance(row[field], str) for field in
                               ("id", "owner_id", "family_id", "permission", "state", "envelope_tag"))
                or any(_IDENTITY.fullmatch(row[field]) is None for field in
                       ("id", "owner_id", "family_id"))
                or type(row["revision"]) is not int or not 1 <= row["revision"] <= 2**63 - 1
                or row["permission"] not in {"granted", "denied"}
                or row["state"] not in {"active", "revoked"}
                or not self._finite(row["expires_at"]) or not self._finite(row["created_at"])
                or row["expires_at"] <= row["created_at"]
                or _DIGEST.fullmatch(row["envelope_tag"]) is None
                or not hmac.compare_digest(row["envelope_tag"], self._subscription_tag(row))):
            raise ValueError("invalid_subscription")
        return row

    def _validate_event(self, row):
        if (row is None or type(row["sequence"]) is not int or not 1 <= row["sequence"] <= 2**63 - 1
                or any(not isinstance(row[field], str) for field in
                       ("id", "recipient_id", "idempotency_key", "envelope_tag"))
                or _IDENTITY.fullmatch(row["id"]) is None
                or _IDENTITY.fullmatch(row["recipient_id"]) is None
                or not 16 <= len(row["idempotency_key"]) <= 128
                or _DIGEST.fullmatch(row["envelope_tag"]) is None
                or type(row["nonce"]) is not bytes or len(row["nonce"]) != 12
                or type(row["ciphertext"]) is not bytes or not 17 <= len(row["ciphertext"]) <= 4096
                or not self._finite(row["created_at"])):
            raise ValueError("invalid_notification")
        value = CreateNotification.model_validate_json(
            self._cipher.decrypt(row["nonce"], row["ciphertext"], self._event_aad(row)))
        body = value.model_dump()
        if (value.recipientUserId != row["recipient_id"]
                or value.idempotencyKey != row["idempotency_key"]
                or not hmac.compare_digest(row["envelope_tag"], self._event_tag(
                    row["recipient_id"], row["idempotency_key"], body))):
            raise ValueError("invalid_notification")
        return value

    def _transaction(self, actor, core_id, home_id, *, write=False):
        self.auth.rate_limit([("local_notification_write" if write else "local_notification_read",
                               actor.id, 240)])
        self._scope(core_id, home_id)
        return self.db.transaction()

    def _current_actor(self, connection, actor):
        self.auth.assert_current(connection, actor)
        row = connection.execute("SELECT * FROM users WHERE id=?", (actor.id,)).fetchone()
        if row is None or row["disabled"] or row["must_change_password"]:
            raise ApiError("invalid_session", 401)
        return row

    def _subscription(self, connection, actor, subscription_id, expected_revision=None,
                      *, require_active=False):
        row = connection.execute(
            "SELECT * FROM local_notification_subscriptions WHERE id=?", (subscription_id,)
        ).fetchone()
        if row is None or row["owner_id"] != actor.id or row["family_id"] != actor.family_id:
            raise ApiError("not_found", 404)
        self._validate_subscription(row)
        if expected_revision is not None and row["revision"] != expected_revision:
            raise ApiError("notification_subscription_changed", 409)
        expired = self.settings.clock() >= row["expires_at"]
        if require_active and (row["state"] != "active" or expired or row["permission"] != "granted"):
            raise ApiError("notification_subscription_inactive", 409)
        return row

    def _public_subscription(self, row):
        state = "expired" if row["state"] == "active" and self.settings.clock() >= row["expires_at"] else row["state"]
        return {"subscription": {"schemaVersion": 1, "ref": {
            **self.scope.model_dump(), "kind": "local_notification_subscription", "id": row["id"]},
            "revision": row["revision"], "permission": row["permission"],
            "state": state, "expiresAt": row["expires_at"]}}

    def register(self, actor, core_id, home_id, value):
        body = RegisterSubscription.model_validate(value)
        now = float(self.settings.clock())
        if not math.isfinite(body.expiresAt) or not now + 60 <= body.expiresAt <= now + 90 * 86400:
            raise ApiError("invalid_request")
        try:
            with self._transaction(actor, core_id, home_id, write=True) as connection:
                self._current_actor(connection, actor)
                old = connection.execute(
                    "SELECT * FROM local_notification_subscriptions WHERE id=?", (body.registrationId,)
                ).fetchone()
                if old is not None:
                    self._validate_subscription(old)
                    if old["owner_id"] != actor.id or old["family_id"] != actor.family_id:
                        raise ApiError("not_found", 404)
                    same = (old["permission"], old["expires_at"]) == (body.permission, body.expiresAt)
                    if not same:
                        raise ApiError("notification_registration_replay", 409)
                    return self._public_subscription(old)
                count = connection.execute("SELECT COUNT(*) FROM local_notification_subscriptions").fetchone()[0]
                if count >= schema.MAX_SUBSCRIPTIONS:
                    raise ApiError("notification_limit_reached", 409)
                row = {"id": body.registrationId, "owner_id": actor.id,
                       "family_id": actor.family_id, "revision": 1,
                       "permission": body.permission, "state": "active",
                       "expires_at": body.expiresAt, "created_at": now}
                row["envelope_tag"] = self._subscription_tag(row)
                connection.execute(
                    "INSERT INTO local_notification_subscriptions VALUES(?,?,?,?,?,?,?,?,?)",
                    tuple(row[field] for field in ("id", "owner_id", "family_id", "revision",
                          "permission", "state", "expires_at", "created_at", "envelope_tag")))
                return self._public_subscription(row)
        except (InvalidTag, ValueError, TypeError, sqlite3.Error, OverflowError):
            raise ApiError("notification_storage_unavailable", 503) from None

    def update(self, actor, core_id, home_id, subscription_id, value):
        body = UpdateSubscription.model_validate(value)
        now = float(self.settings.clock())
        if not math.isfinite(body.expiresAt) or not now + 60 <= body.expiresAt <= now + 90 * 86400:
            raise ApiError("invalid_request")
        try:
            with self._transaction(actor, core_id, home_id, write=True) as connection:
                self._current_actor(connection, actor)
                old = self._subscription(connection, actor, subscription_id, body.expectedRevision)
                if old["state"] != "active" or now >= old["expires_at"]:
                    raise ApiError("notification_subscription_inactive", 409)
                row = dict(old)
                row.update(revision=old["revision"] + 1, permission=body.permission,
                           expires_at=body.expiresAt)
                row["envelope_tag"] = self._subscription_tag(row)
                connection.execute(
                    "UPDATE local_notification_subscriptions SET revision=?,permission=?,expires_at=?,envelope_tag=? WHERE id=?",
                    (row["revision"], row["permission"], row["expires_at"], row["envelope_tag"], row["id"]))
                return self._public_subscription(row)
        except (InvalidTag, ValueError, TypeError, sqlite3.Error, OverflowError):
            raise ApiError("notification_storage_unavailable", 503) from None

    def revoke(self, actor, core_id, home_id, subscription_id, expected_revision):
        try:
            with self._transaction(actor, core_id, home_id, write=True) as connection:
                self._current_actor(connection, actor)
                old = self._subscription(connection, actor, subscription_id, expected_revision)
                if old["state"] == "revoked":
                    return
                row = dict(old)
                row.update(revision=old["revision"] + 1, state="revoked")
                row["envelope_tag"] = self._subscription_tag(row)
                connection.execute(
                    "UPDATE local_notification_subscriptions SET revision=?,state='revoked',envelope_tag=? WHERE id=?",
                    (row["revision"], row["envelope_tag"], row["id"]))
        except (InvalidTag, ValueError, TypeError, sqlite3.Error, OverflowError):
            raise ApiError("notification_storage_unavailable", 503) from None

    def enqueue(self, actor, core_id, home_id, value):
        body = CreateNotification.model_validate(value)
        now = float(self.settings.clock())
        try:
            with self._transaction(actor, core_id, home_id, write=True) as connection:
                user = self._current_actor(connection, actor)
                if user["role"] != "admin":
                    raise ApiError("forbidden", 403)
                recipient = connection.execute(
                    "SELECT * FROM users WHERE id=?", (body.recipientUserId,)
                ).fetchone()
                if recipient is None or recipient["disabled"] or recipient["must_change_password"]:
                    raise ApiError("not_found", 404)
                packed = body.model_dump()
                tag = self._event_tag(body.recipientUserId, body.idempotencyKey, packed)
                old = connection.execute(
                    "SELECT * FROM local_notification_events WHERE recipient_id=? AND idempotency_key=?",
                    (body.recipientUserId, body.idempotencyKey),
                ).fetchone()
                if old is not None:
                    self._validate_event(old)
                    if not hmac.compare_digest(old["envelope_tag"], tag):
                        raise ApiError("notification_event_conflict", 409)
                    return {"notification": self._public_event(old, body, False)}
                if connection.execute("SELECT COUNT(*) FROM local_notification_events").fetchone()[0] >= schema.MAX_EVENTS:
                    raise ApiError("notification_limit_reached", 409)
                event_id, nonce = uuid.uuid4().hex, secrets.token_bytes(12)
                cursor = connection.execute(
                    "INSERT INTO local_notification_events(id,recipient_id,idempotency_key,envelope_tag,nonce,ciphertext,created_at) "
                    "VALUES(?,?,?,?,?,x'',?)",
                    (event_id, body.recipientUserId, body.idempotencyKey, tag, nonce, now),
                )
                sequence = cursor.lastrowid
                row = {"sequence": sequence, "id": event_id, "recipient_id": body.recipientUserId,
                       "idempotency_key": body.idempotencyKey, "envelope_tag": tag,
                       "nonce": nonce, "created_at": now}
                plain = body.model_dump_json().encode("utf-8")
                ciphertext = self._cipher.encrypt(nonce, plain, self._event_aad(row))
                connection.execute("UPDATE local_notification_events SET ciphertext=? WHERE sequence=?",
                                   (ciphertext, sequence))
                row["ciphertext"] = ciphertext
                return {"notification": self._public_event(row, body, False)}
        except (InvalidTag, ValueError, TypeError, sqlite3.Error, OverflowError):
            raise ApiError("notification_storage_unavailable", 503) from None

    def _public_event(self, row, body, acknowledged, delivered=False):
        private = body.sensitivity == "private"
        projection = ({"title": "Larenor", "body": "", "target": None, "redacted": True}
                      if private else {"title": body.title, "body": body.body,
                                       "target": body.target, "redacted": False})
        return {"schemaVersion": 1, "id": row["id"], "sequence": row["sequence"],
                "category": body.category, "sensitivity": body.sensitivity,
                "title": body.title, "body": body.body, "target": body.target,
                "createdAt": row["created_at"],
                "deliveryState": "delivered" if delivered else "available",
                "readState": "read" if acknowledged else "unread",
                "acknowledged": acknowledged,
                "publicProjection": projection}

    def pull(self, actor, core_id, home_id, subscription_id, expected_revision, *, after=0, limit=50):
        if type(after) is not int or not 0 <= after <= 2**63 - 1 or type(limit) is not int or not 1 <= limit <= 100:
            raise ApiError("invalid_request")
        try:
            with self._transaction(actor, core_id, home_id) as connection:
                self._current_actor(connection, actor)
                subscription = self._subscription(connection, actor, subscription_id,
                                                  expected_revision, require_active=True)
                rows = connection.execute(
                    "SELECT e.*,CASE WHEN a.acknowledged_at IS NULL THEN 0 ELSE 1 END AS acknowledged "
                    "FROM local_notification_events e LEFT JOIN local_notification_acks a "
                    "ON a.subscription_id=? AND a.sequence=e.sequence "
                    "WHERE e.recipient_id=? AND e.sequence>? AND NOT EXISTS ("
                    "SELECT 1 FROM local_notification_acks retired_delivery "
                    "JOIN local_notification_subscriptions retired_subscription "
                    "ON retired_subscription.id=retired_delivery.subscription_id "
                    "WHERE retired_delivery.sequence=e.sequence "
                    "AND retired_subscription.owner_id=e.recipient_id "
                    "AND (retired_subscription.state='revoked' "
                    "OR retired_subscription.expires_at<=?)) "
                    "ORDER BY e.sequence LIMIT ?",
                    (subscription_id, actor.id, after, float(self.settings.clock()), limit + 1),
                ).fetchall()
                selected = rows[:limit]
                existing_rows = connection.execute(
                    "SELECT sequence FROM local_notification_acks WHERE subscription_id=? "
                    "AND sequence IN (" + ",".join("?" for _ in selected) + ")",
                    (subscription_id, *(row["sequence"] for row in selected)),
                ).fetchall() if selected else []
                existing = {row["sequence"] for row in existing_rows}
                total = connection.execute("SELECT COUNT(*) FROM local_notification_acks").fetchone()[0]
                if total + len(selected) - len(existing) > schema.MAX_DELIVERIES:
                    raise ApiError("notification_limit_reached", 409)
                now = float(self.settings.clock())
                pending = [row for row in selected if row["sequence"] not in existing]
                connection.executemany(
                    "INSERT INTO local_notification_acks(subscription_id,sequence,delivered_at,acknowledged_at) "
                    "VALUES(?,?,?,NULL)",
                    [(subscription_id, row["sequence"], now) for row in pending],
                )
                events = [self._public_event(row, self._validate_event(row),
                                             bool(row["acknowledged"]), True)
                          for row in selected]
                return {"schemaVersion": 1, "scope": self.scope.model_dump(),
                        "subscriptionRevision": subscription["revision"], "events": events,
                        "nextAfter": events[-1]["sequence"] if len(rows) > limit else None}
        except (InvalidTag, ValueError, TypeError, sqlite3.Error, OverflowError):
            raise ApiError("notification_storage_unavailable", 503) from None

    def acknowledge(self, actor, core_id, home_id, subscription_id, value):
        body = AcknowledgeNotifications.model_validate(value)
        try:
            with self._transaction(actor, core_id, home_id, write=True) as connection:
                self._current_actor(connection, actor)
                subscription = self._subscription(connection, actor, subscription_id,
                                                  body.expectedSubscriptionRevision,
                                                  require_active=True)
                placeholders = ",".join("?" for _ in body.sequences)
                found = connection.execute(
                    f"SELECT sequence FROM local_notification_events WHERE recipient_id=? "
                    f"AND sequence IN ({placeholders}) ORDER BY sequence",
                    (actor.id, *body.sequences),
                ).fetchall()
                if [row["sequence"] for row in found] != body.sequences:
                    raise ApiError("not_found", 404)
                delivered = connection.execute(
                    f"SELECT sequence FROM local_notification_acks WHERE subscription_id=? "
                    f"AND sequence IN ({placeholders}) ORDER BY sequence",
                    (subscription_id, *body.sequences),
                ).fetchall()
                if [row["sequence"] for row in delivered] != body.sequences:
                    raise ApiError("notification_not_delivered", 409)
                now = float(self.settings.clock())
                connection.executemany(
                    "UPDATE local_notification_acks SET acknowledged_at=COALESCE(acknowledged_at,?) "
                    "WHERE subscription_id=? AND sequence=?",
                    [(now, subscription_id, sequence) for sequence in body.sequences],
                )
                return {"schemaVersion": 1, "subscriptionRevision": subscription["revision"],
                        "acknowledgedThrough": body.sequences[-1]}
        except (InvalidTag, ValueError, TypeError, sqlite3.Error, OverflowError):
            raise ApiError("notification_storage_unavailable", 503) from None

    def validate_storage(self):
        try:
            with self.db.connection() as connection:
                subscriptions = connection.execute(
                    "SELECT * FROM local_notification_subscriptions LIMIT ?", (schema.MAX_SUBSCRIPTIONS + 1,)
                ).fetchall()
                events = connection.execute(
                    "SELECT * FROM local_notification_events ORDER BY sequence LIMIT ?", (schema.MAX_EVENTS + 1,)
                ).fetchall()
                if len(subscriptions) > schema.MAX_SUBSCRIPTIONS or len(events) > schema.MAX_EVENTS:
                    raise ValueError("capacity")
                for row in subscriptions:
                    self._validate_subscription(row)
                for row in events:
                    self._validate_event(row)
                invalid = connection.execute(
                    "SELECT COUNT(*) FROM local_notification_acks a "
                    "LEFT JOIN local_notification_subscriptions s ON s.id=a.subscription_id "
                    "LEFT JOIN local_notification_events e ON e.sequence=a.sequence "
                    "WHERE s.id IS NULL OR e.sequence IS NULL OR s.owner_id<>e.recipient_id"
                ).fetchone()[0]
                deliveries = connection.execute(
                    "SELECT * FROM local_notification_acks LIMIT ?", (schema.MAX_DELIVERIES + 1,)
                ).fetchall()
                if invalid or len(deliveries) > schema.MAX_DELIVERIES or any(
                    not self._finite(row["delivered_at"])
                    or (row["acknowledged_at"] is not None and (
                        not self._finite(row["acknowledged_at"])
                        or row["acknowledged_at"] < row["delivered_at"]))
                    for row in deliveries
                ):
                    raise ValueError("invalid_ack")
        except (InvalidTag, ValueError, TypeError, sqlite3.Error, OverflowError):
            raise StartupError("local_notification_storage_invalid") from None
