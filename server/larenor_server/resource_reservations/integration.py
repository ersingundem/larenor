"""Bind the F40 reducer to the authenticated Core home and account."""

from datetime import UTC, datetime
import hashlib
import hmac
import json
from zoneinfo import ZoneInfo

from ..errors import ApiError
from .service import ReservationAuthority, ReservationStore, ResourceRule


class ResourceReservationService:
    def __init__(self, db, auth, settings, key, context):
        self.db, self.auth, self.settings, self.context = db, auth, settings, context
        encryption = hmac.new(key, b"resource-reservations-encryption-v1", hashlib.sha256).digest()
        audit = hmac.new(key, b"resource-reservations-audit-v1", hashlib.sha256).digest()
        self.store = ReservationStore(db, encryption_key=encryption, audit_key=audit)

    def _scope(self, core_id, home_id):
        if (core_id, home_id) != (self.context.coreId, self.context.homeId):
            raise ApiError("not_found", 404)

    def _resource_id(self):
        return hashlib.sha256(
            f"larenor-shared-resource-v1:{self.context.coreId}:{self.context.homeId}".encode("ascii")
        ).hexdigest()[:32]

    def _facts(self, actor):
        with self.db.connection() as connection:
            self.auth.assert_current(connection, actor)
            account = connection.execute(
                "SELECT revision,role,disabled,must_change_password FROM users WHERE id=?",
                (actor.id,),
            ).fetchone()
            members = connection.execute(
                "SELECT id,revision FROM users WHERE disabled=0 AND must_change_password=0 ORDER BY id"
            ).fetchall()
            state = connection.execute(
                "SELECT revision FROM resource_reservation_state WHERE core_id=? AND home_id=? AND resource_id=?",
                (self.context.coreId, self.context.homeId, self._resource_id()),
            ).fetchone()
        if account is None or account["disabled"] or account["must_change_password"]:
            raise ApiError("invalid_session", 401)
        member_ids = tuple(row["id"] for row in members)
        if actor.id not in member_ids:
            raise ApiError("forbidden", 403)
        members_revision = sum(row["revision"] for row in members)
        if not 1 <= members_revision <= 2**63 - 1:
            raise ApiError("authority_changed", 409)
        return account, member_ids, members_revision, 1 if state is None else state["revision"]

    def authority(self, actor, core_id, home_id, resource_id=None):
        self._scope(core_id, home_id)
        expected = self._resource_id()
        if resource_id is not None and resource_id != expected:
            raise ApiError("not_found", 404)
        account, members, members_revision, calendar_revision = self._facts(actor)
        return ReservationAuthority(
            core_id=self.context.coreId,
            home_id=self.context.homeId,
            account_id=actor.id,
            core_revision=1,
            home_revision=1,
            account_revision=account["revision"],
            members_revision=members_revision,
            calendar_revision=calendar_revision,
            member_ids=members,
            resource=ResourceRule(
                id=expected,
                revision=1,
                capacity=1,
                timezone="UTC",
                member_ids=members,
            ),
        )

    def _expected(self, actor, core_id, home_id, resource_id, body, *, receipt=False):
        current = self.authority(actor, core_id, home_id, resource_id)
        expected = body.authority_fields()
        actual = {
            "coreId": current.core_id,
            "homeId": current.home_id,
            "accountId": current.account_id,
            "coreRevision": current.core_revision,
            "homeRevision": current.home_revision,
            "accountRevision": current.account_revision,
            "membersRevision": current.members_revision,
            "resourceId": current.resource.id,
            "resourceRevision": current.resource.revision,
            "expectedCalendarRevision": current.calendar_revision,
            "sessionId": actor.family_id,
        }
        if receipt:
            # A lost-ACK reader necessarily holds the pre-command calendar
            # revision. Bind every identity/revision field, but resolve the
            # receipt against the current tamper-verified journal.
            expected_calendar = expected.pop("expectedCalendarRevision")
            actual.pop("expectedCalendarRevision")
            if expected != actual or expected_calendar > current.calendar_revision:
                raise ApiError("authority_changed", 409)
        elif expected != actual:
            raise ApiError("authority_changed", 409)
        return current

    @staticmethod
    def _recurrence(reservation):
        count = len(reservation.occurrences)
        if count == 1:
            return {"frequency": "none", "count": 1}
        zone = ZoneInfo(reservation.timezone)
        starts = [datetime.fromisoformat(item.start_utc[:-1]).replace(tzinfo=UTC)
                  .astimezone(zone).replace(tzinfo=None)
                  for item in reservation.occurrences]
        days = (starts[1].date() - starts[0].date()).days
        frequency = "daily" if days == 1 else "weekly" if days == 7 else None
        if frequency is None or any((right.date() - left.date()).days != days
                                    for left, right in zip(starts, starts[1:])):
            raise ApiError("server_unavailable", 503)
        return {"frequency": frequency, "count": count}

    @classmethod
    def _reservation(cls, item, actor):
        zone = ZoneInfo(item.timezone)
        first = datetime.fromisoformat(item.occurrences[0].start_utc[:-1]).replace(tzinfo=UTC)
        return {
            "id": item.id,
            "ownerId": item.owner_id,
            "resourceId": item.resource_id,
            "timezone": item.timezone,
            "localStart": item.local_start,
            "fold": first.astimezone(zone).fold,
            "durationSeconds": item.duration_seconds,
            "units": item.units,
            "recurrence": cls._recurrence(item),
            "occurrences": [{"startUtc": value.start_utc, "endUtc": value.end_utc}
                            for value in item.occurrences],
            "canCancel": item.cancelled_at is None and
                         (actor.role == "admin" or item.owner_id == actor.id),
            "cancelled": item.cancelled_at is not None,
        }

    @staticmethod
    def _authority_json(authority, actor):
        return {
            "coreId": authority.core_id,
            "homeId": authority.home_id,
            "accountId": authority.account_id,
            "sessionId": actor.family_id,
            "coreRevision": authority.core_revision,
            "homeRevision": authority.home_revision,
            "accountRevision": authority.account_revision,
            "membersRevision": authority.members_revision,
            "resourceId": authority.resource.id,
            "resourceRevision": authority.resource.revision,
        }

    def bootstrap(self, actor, core_id, home_id):
        authority = self.authority(actor, core_id, home_id)
        return {
            "schemaVersion": 1,
            "authority": self._authority_json(authority, actor),
            "calendarRevision": authority.calendar_revision,
            "resource": {
                "id": authority.resource.id,
                "revision": authority.resource.revision,
                "label": "Shared home resource",
                "timezone": authority.resource.timezone,
                "capacity": authority.resource.capacity,
            },
        }

    def snapshot(self, actor, core_id, home_id, resource_id, body):
        authority = self._expected(actor, core_id, home_id, resource_id, body)
        exported = self.store.export(actor, authority=authority, limit=256)
        events = self.store.history(actor, authority=authority, limit=256)
        reservations = []
        # Export intentionally omits internal receipt data. Re-open verified
        # records only through the reducer's bounded read.
        with self.db.connection() as connection:
            _, records = self.store._verified(connection, authority)
        for item in sorted(records.values(), key=lambda value: (value.created_at, value.id)):
            reservations.append(self._reservation(item, actor))
        busy = [
            {"startUtc": occurrence["startUtc"], "endUtc": occurrence["endUtc"],
             "units": item["units"]}
            for item in exported["reservations"] if not item["cancelled"]
            for occurrence in item["occurrences"]
        ]
        if len(busy) > 256:
            raise ApiError("availability_limit_reached", 413)
        return {
            "schemaVersion": 1,
            "authority": self._authority_json(authority, actor),
            "calendarRevision": authority.calendar_revision,
            "resource": {
                "id": authority.resource.id,
                "revision": authority.resource.revision,
                "label": "Shared home resource",
                "timezone": authority.resource.timezone,
                "capacity": authority.resource.capacity,
            },
            "canCreate": True,
            "reservations": reservations,
            "history": [{
                "eventId": event.event_id,
                "action": "create" if event.action == "created" else "cancel",
                "actorId": event.actor_id,
                "reservationId": event.reservation_id,
                "calendarRevision": event.calendar_revision,
            } for event in events],
            "busy": sorted(busy, key=lambda value: (value["startUtc"], value["endUtc"])),
        }

    def create(self, actor, core_id, home_id, resource_id, body):
        authority = self._expected(actor, core_id, home_id, resource_id, body)
        receipt = self.store.create(
            actor,
            authority=authority,
            command_bytes=json.dumps(body.command("create"), sort_keys=True,
                                     separators=(",", ":")).encode(),
        )
        return self._receipt_json(receipt, authority, actor)

    def cancel(self, actor, core_id, home_id, resource_id, body):
        authority = self._expected(actor, core_id, home_id, resource_id, body)
        receipt = self.store.cancel(
            actor,
            authority=authority,
            command_bytes=json.dumps(body.command("cancel"), sort_keys=True,
                                     separators=(",", ":")).encode(),
        )
        return self._receipt_json(receipt, authority, actor)

    def receipt(self, actor, core_id, home_id, resource_id, command_id, body):
        authority = self._expected(
            actor, core_id, home_id, resource_id, body, receipt=True,
        )
        receipt = self.store.receipt(
            actor, authority=authority, command_id=command_id,
        )
        if receipt is None:
            return None
        if receipt.calendar_revision != body.expectedCalendarRevision + 1:
            raise ApiError("authority_changed", 409)
        return self._receipt_json(receipt, authority, actor)

    def export(self, actor, core_id, home_id, resource_id, body):
        authority = self._expected(actor, core_id, home_id, resource_id, body)
        value = self.store.export(actor, authority=authority, limit=body.limit)
        exported_ids = {item["id"] for item in value["reservations"]}
        records = [item for item in self._verified_records(authority)
                   if item.id in exported_ids]
        if len(records) != len(exported_ids):
            raise ApiError("audit_tampered", 503)
        return {
            "schemaVersion": 1,
            "authority": self._authority_json(authority, actor),
            "calendarRevision": value["calendarRevision"],
            "reservations": [
                self._reservation(item, actor)
                for item in records
            ],
        }

    def _verified_records(self, authority):
        with self.db.connection() as connection:
            _, records = self.store._verified(connection, authority)
        return sorted(records.values(), key=lambda value: (value.created_at, value.id))

    def _receipt_json(self, receipt, authority, actor):
        return {
            "schemaVersion": 1,
            "authority": self._authority_json(authority, actor),
            "eventId": receipt.event_id,
            "actorId": actor.id,
            "commandId": receipt.command_id,
            "action": "create" if receipt.action == "created" else "cancel",
            "expectedCalendarRevision": receipt.calendar_revision - 1,
            "calendarRevision": receipt.calendar_revision,
            "reservation": self._reservation(receipt.reservation, actor),
        }
