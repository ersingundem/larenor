import hashlib
import hmac
import json

from ..errors import ApiError
from .service import MAX_MEMBERS, FairChoreStore, HouseholdMembers


class FairChoreService:
    """Authenticated Core boundary for the durable chore reducer."""

    def __init__(
        self, db, auth, settings, context, key: bytes, *, notification_writer=None
    ):
        self.db, self.auth, self.settings = db, auth, settings
        self.context = context
        self.store = FairChoreStore(
            db,
            audit_key=hmac.new(
                key, b"larenor-fair-chores-audit-v1", hashlib.sha256
            ).digest(),
            write_guard=self._assert_write_current,
            notification_writer=notification_writer,
        )
        self._members_key = hmac.new(
            key, b"larenor-fair-chores-members-v1", hashlib.sha256
        ).digest()

    def _scope(self, core_id, home_id):
        if (core_id, home_id) != (self.context.coreId, self.context.homeId):
            raise ApiError("not_found", 404)

    def _members_in(self, connection, actor):
        self.auth.assert_current(connection, actor)
        rows = connection.execute(
            "SELECT id,username,role,revision FROM users WHERE disabled=0 "
            "AND must_change_password=0 ORDER BY created_at,id"
        ).fetchall()
        if not rows or not any(row["id"] == actor.id for row in rows):
            raise ApiError("invalid_session", 401)
        if len(rows) > MAX_MEMBERS:
            raise ApiError("fair_chore_members_limit_reached", 413)
        payload = json.dumps(
            [
                [row["id"], row["username"], row["role"], row["revision"]]
                for row in rows
            ],
            ensure_ascii=False,
            separators=(",", ":"),
        ).encode("utf-8")
        revision = int.from_bytes(
            hmac.new(self._members_key, payload, hashlib.sha256).digest()[:8], "big"
        ) & (2**53 - 1)
        members = HouseholdMembers(max(1, revision), tuple(row["id"] for row in rows))
        labels = {row["id"]: row["username"] for row in rows}
        return members, labels

    def _members(self, actor, *, write=False):
        self.auth.rate_limit(
            [("fair_chore_write" if write else "fair_chore_read", actor.id, 240)]
        )
        with self.db.connection() as connection:
            return self._members_in(connection, actor)

    def _assert_write_current(self, connection, actor, members):
        current, _labels = self._members_in(connection, actor)
        if current != members:
            raise ApiError("authority_changed", 409)

    def _postflight(self, actor, expected):
        with self.db.connection() as connection:
            current, labels = self._members_in(connection, actor)
        if current != expected:
            raise ApiError("authority_changed", 409)
        return labels

    def _authority(self, actor, members):
        return {
            "schemaVersion": 2,
            "coreId": self.context.coreId,
            "homeId": self.context.homeId,
            "accountId": actor.id,
            "sessionId": actor.family_id,
            "membersRevision": members.revision,
            "canManage": actor.role == "admin",
        }

    @staticmethod
    def _task(task, actor, members, labels=None):
        labels = labels or {}
        active = tuple(item for item in task.member_order if item in members.ids)
        active += tuple(item for item in members.ids if item not in active)
        assignee_active = task.assignee_id in members.ids
        may_act = actor.role == "admin" or actor.id == task.assignee_id
        return {
            "schemaVersion": 2,
            "id": task.id,
            "title": task.title,
            "revision": task.revision,
            "assigneeId": task.assignee_id,
            "assigneeLabel": labels.get(task.assignee_id, task.assignee_id),
            "dueAt": task.due_at,
            "timezone": task.timezone_name,
            "intervalDays": task.interval_days,
            "memberOrder": [
                {
                    "schemaVersion": 1,
                    "id": identifier,
                    "label": labels[identifier],
                }
                for identifier in active
            ],
            "permissions": {
                "complete": may_act and assignee_active,
                "defer": may_act and assignee_active,
                "skip": may_act
                or (
                    not assignee_active
                    and actor.id in members.ids
                ),
            },
        }

    def list(self, actor, core_id, home_id):
        self._scope(core_id, home_id)
        members, labels = self._members(actor)
        tasks = self.store.list(
            actor,
            core_id=core_id,
            home_id=home_id,
            current_members=members,
        )
        labels = self._postflight(actor, members)
        return {
            "schemaVersion": 2,
            "authority": self._authority(actor, members),
            "members": [
                {
                    "schemaVersion": 1,
                    "id": identifier,
                    "label": labels[identifier],
                }
                for identifier in members.ids
            ],
            "tasks": [self._task(task, actor, members, labels) for task in tasks],
        }

    def create(self, actor, core_id, home_id, body):
        self._scope(core_id, home_id)
        members, labels = self._members(actor, write=True)
        if body.expectedMembersRevision != members.revision:
            raise ApiError("authority_changed", 409)
        if actor.role != "admin":
            raise ApiError("forbidden", 403)
        # The command id is retained in the created event and rejects another
        # meaning for the same task event; task creation itself stays admin only.
        receipt = self.store.create(
            actor,
            core_id=core_id,
            home_id=home_id,
            title=body.title,
            members=members,
            timezone_name=body.timezone,
            interval_days=body.intervalDays,
            due_at=body.dueAt,
            command_id=body.commandId,
        )
        labels = self._postflight(actor, members)
        return self._receipt(actor, members, receipt, labels)

    def complete(self, actor, core_id, home_id, task_id, body):
        self._scope(core_id, home_id)
        members, labels = self._members(actor, write=True)
        if body.expectedMembersRevision != members.revision:
            raise ApiError("authority_changed", 409)
        receipt = self.store.complete(
            actor,
            task_id,
            core_id=core_id,
            home_id=home_id,
            expected_revision=body.expectedRevision,
            command_id=body.commandId,
            # Device wall clocks can drift; Core owns the next due date.
            completed_at=self.settings.clock(),
            members=members,
        )
        labels = self._postflight(actor, members)
        return self._receipt(actor, members, receipt, labels)

    def defer(self, actor, core_id, home_id, task_id, body):
        self._scope(core_id, home_id)
        members, labels = self._members(actor, write=True)
        if body.expectedMembersRevision != members.revision:
            raise ApiError("authority_changed", 409)
        receipt = self.store.defer(
            actor,
            task_id,
            core_id=core_id,
            home_id=home_id,
            expected_revision=body.expectedRevision,
            command_id=body.commandId,
            days=body.days,
            members=members,
        )
        labels = self._postflight(actor, members)
        return self._receipt(actor, members, receipt, labels)

    def skip(self, actor, core_id, home_id, task_id, body):
        self._scope(core_id, home_id)
        members, labels = self._members(actor, write=True)
        if body.expectedMembersRevision != members.revision:
            raise ApiError("authority_changed", 409)
        receipt = self.store.skip(
            actor,
            task_id,
            core_id=core_id,
            home_id=home_id,
            expected_revision=body.expectedRevision,
            command_id=body.commandId,
            members=members,
        )
        labels = self._postflight(actor, members)
        return self._receipt(actor, members, receipt, labels)

    def receipt(self, actor, core_id, home_id, command_id):
        self._scope(core_id, home_id)
        members, labels = self._members(actor)
        receipt = self.store.receipt(
            actor, command_id, core_id=core_id, home_id=home_id
        )
        labels = self._postflight(actor, members)
        return (
            None if receipt is None else self._receipt(actor, members, receipt, labels)
        )

    def _receipt(self, actor, members, receipt, labels):
        return {
            "schemaVersion": 2,
            "authority": self._authority(actor, members),
            "eventId": receipt.event_id,
            "commandId": receipt.command_id,
            "action": receipt.action,
            "task": self._task(receipt.task, actor, members, labels),
        }
