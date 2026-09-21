from dataclasses import asdict, dataclass
from datetime import datetime, timedelta
import hashlib
import hmac
import json
import math
import sqlite3
import time
import uuid
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from ..auth import Principal
from ..database import Database
from ..errors import ApiError, StartupError


MAX_MEMBERS = 32
MAX_TITLE_LENGTH = 200
MAX_HISTORY = 10_000


def _identifier(value: str) -> bool:
    return (
        isinstance(value, str)
        and 1 <= len(value) <= 128
        and all(char.isalnum() or char in "-_.:" for char in value)
    )


@dataclass(frozen=True)
class HouseholdMembers:
    revision: int
    ids: tuple[str, ...]

    def __post_init__(self) -> None:
        if (
            type(self.revision) is not int
            or self.revision < 1
            or not isinstance(self.ids, tuple)
            or not 1 <= len(self.ids) <= MAX_MEMBERS
            or len(set(self.ids)) != len(self.ids)
            or any(not _identifier(identifier) for identifier in self.ids)
        ):
            raise ValueError("invalid_household_members")


@dataclass(frozen=True)
class ChoreTask:
    id: str
    core_id: str
    home_id: str
    title: str
    revision: int
    assignee_id: str
    members_revision: int
    member_order: tuple[str, ...]
    timezone_name: str
    interval_days: int
    due_at: float


@dataclass(frozen=True)
class ChoreReceipt:
    event_id: str
    action: str
    task: ChoreTask


@dataclass(frozen=True)
class ChoreEvent:
    event_id: str
    action: str
    actor_id: str
    revision: int
    occurred_at: float


class FairChoreStore:
    """Durable fair rotation with explicit scope, revision and audit authority."""

    def __init__(self, database: Database, *, audit_key: bytes):
        if not isinstance(audit_key, bytes) or len(audit_key) != 32:
            raise ValueError("invalid_audit_key")
        self.database = database
        self._audit_key = audit_key

    @staticmethod
    def _task(row: sqlite3.Row) -> ChoreTask:
        try:
            order = json.loads(row["member_order_json"])
            if (
                not isinstance(order, list)
                or not order
                or not all(_identifier(item) for item in order)
            ):
                raise ValueError
            task = ChoreTask(
                id=row["id"],
                core_id=row["core_id"],
                home_id=row["home_id"],
                title=row["title"],
                revision=row["revision"],
                assignee_id=row["assignee_id"],
                members_revision=row["members_revision"],
                member_order=tuple(order),
                timezone_name=row["timezone_name"],
                interval_days=row["interval_days"],
                due_at=row["due_at"],
            )
            ZoneInfo(task.timezone_name)
            if task.assignee_id not in task.member_order:
                raise ValueError
            return task
        except (
            KeyError,
            TypeError,
            ValueError,
            json.JSONDecodeError,
            ZoneInfoNotFoundError,
        ):
            raise StartupError("fair_chore_storage_invalid") from None

    @staticmethod
    def _receipt_json(receipt: ChoreReceipt) -> str:
        return json.dumps(
            {
                "event_id": receipt.event_id,
                "action": receipt.action,
                "task": asdict(receipt.task),
            },
            ensure_ascii=False,
            sort_keys=True,
            separators=(",", ":"),
        )

    @staticmethod
    def _receipt(raw: str) -> ChoreReceipt:
        try:
            value = json.loads(raw)
            task = value["task"]
            task["member_order"] = tuple(task["member_order"])
            return ChoreReceipt(value["event_id"], value["action"], ChoreTask(**task))
        except (KeyError, TypeError, ValueError, json.JSONDecodeError):
            raise StartupError("fair_chore_history_invalid") from None

    def _event_hash(self, values: tuple[object, ...]) -> str:
        payload = json.dumps(values, ensure_ascii=False, separators=(",", ":")).encode()
        return hmac.new(
            self._audit_key, b"larenor-fair-chore-event-v1\0" + payload, hashlib.sha256
        ).hexdigest()

    def _append(
        self,
        connection: sqlite3.Connection,
        *,
        task: ChoreTask,
        command_id: str,
        action: str,
        actor_id: str,
        occurred_at: float,
    ) -> ChoreReceipt:
        if (
            connection.execute("SELECT COUNT(*) FROM fair_chore_events").fetchone()[0]
            >= MAX_HISTORY
        ):
            raise ApiError("fair_chore_history_limit_reached", 413)
        sequence = connection.execute(
            "SELECT COALESCE(MAX(sequence),0)+1 FROM fair_chore_events"
        ).fetchone()[0]
        previous = connection.execute(
            "SELECT event_hash FROM fair_chore_events WHERE task_id=? ORDER BY sequence DESC LIMIT 1",
            (task.id,),
        ).fetchone()
        previous_hash = "" if previous is None else previous["event_hash"]
        receipt = ChoreReceipt(uuid.uuid4().hex, action, task)
        raw = self._receipt_json(receipt)
        values = (
            sequence,
            receipt.event_id,
            task.id,
            command_id,
            action,
            actor_id,
            task.revision,
            occurred_at,
            raw,
            previous_hash,
        )
        digest = self._event_hash(values)
        connection.execute(
            "INSERT INTO fair_chore_events VALUES(?,?,?,?,?,?,?,?,?,?,?)",
            (*values, digest),
        )
        return receipt

    @staticmethod
    def _validate_scope(core_id: str, home_id: str) -> None:
        if not _identifier(core_id) or not _identifier(home_id):
            raise ApiError("invalid_request", 400)

    def _load(
        self,
        connection: sqlite3.Connection,
        task_id: str,
        core_id: str,
        home_id: str,
    ) -> ChoreTask:
        self._validate_scope(core_id, home_id)
        if not _identifier(task_id):
            raise ApiError("not_found", 404)
        row = connection.execute(
            "SELECT * FROM fair_chore_tasks WHERE id=? AND core_id=? AND home_id=?",
            (task_id, core_id, home_id),
        ).fetchone()
        if row is None:
            raise ApiError("not_found", 404)
        return self._task(row)

    def create(
        self,
        actor: Principal,
        *,
        core_id: str,
        home_id: str,
        title: str,
        members: HouseholdMembers,
        timezone_name: str,
        interval_days: int,
        due_at: float,
    ) -> ChoreTask:
        self._validate_scope(core_id, home_id)
        if actor.role != "admin":
            raise ApiError("forbidden", 403)
        try:
            timezone = ZoneInfo(timezone_name)
        except (TypeError, ZoneInfoNotFoundError):
            raise ApiError("invalid_request", 400) from None
        if (
            not isinstance(title, str)
            or not 1 <= len(title.strip()) <= MAX_TITLE_LENGTH
            or type(interval_days) is not int
            or not 1 <= interval_days <= 365
            or not isinstance(due_at, (int, float))
            or isinstance(due_at, bool)
            or not math.isfinite(due_at)
        ):
            raise ApiError("invalid_request", 400)
        datetime.fromtimestamp(due_at, timezone)
        now = time.time()
        task = ChoreTask(
            id=uuid.uuid4().hex,
            core_id=core_id,
            home_id=home_id,
            title=title.strip(),
            revision=1,
            assignee_id=members.ids[0],
            members_revision=members.revision,
            member_order=members.ids,
            timezone_name=timezone_name,
            interval_days=interval_days,
            due_at=float(due_at),
        )
        with self.database.transaction() as connection:
            connection.execute(
                "INSERT INTO fair_chore_tasks VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)",
                (
                    task.id,
                    core_id,
                    home_id,
                    task.title,
                    1,
                    task.assignee_id,
                    members.revision,
                    json.dumps(members.ids, separators=(",", ":")),
                    timezone_name,
                    interval_days,
                    task.due_at,
                    now,
                    now,
                ),
            )
            self._append(
                connection,
                task=task,
                command_id=f"create:{task.id}",
                action="created",
                actor_id=actor.id,
                occurred_at=now,
            )
        return task

    def get(
        self,
        actor: Principal,
        task_id: str,
        *,
        core_id: str,
        home_id: str,
    ) -> ChoreTask:
        with self.database.connection() as connection:
            task = self._load(connection, task_id, core_id, home_id)
            self._assert_current(connection, task)
            self._authorize_read(actor, task)
            return task

    @staticmethod
    def _authorize_read(actor: Principal, task: ChoreTask) -> None:
        if actor.role != "admin" and actor.id not in task.member_order:
            raise ApiError("forbidden", 403)

    def _assert_current(
        self,
        connection: sqlite3.Connection,
        task: ChoreTask,
    ) -> None:
        self._verified_history(connection, task.id)
        row = connection.execute(
            "SELECT receipt_json FROM fair_chore_events WHERE task_id=? "
            "ORDER BY sequence DESC LIMIT 1",
            (task.id,),
        ).fetchone()
        if row is None or self._receipt(row["receipt_json"]).task != task:
            raise StartupError("fair_chore_history_invalid")

    def _replay(
        self,
        connection: sqlite3.Connection,
        task: ChoreTask,
        command_id: str,
        actor: Principal,
        expected_action: str,
    ) -> ChoreReceipt | None:
        row = connection.execute(
            "SELECT actor_id,receipt_json FROM fair_chore_events WHERE task_id=? AND command_id=?",
            (task.id, command_id),
        ).fetchone()
        if row is None:
            return None
        if row["actor_id"] != actor.id and actor.role != "admin":
            raise ApiError("forbidden", 403)
        self._verified_history(connection, task.id)
        receipt = self._receipt(row["receipt_json"])
        if receipt.action != expected_action:
            raise ApiError("idempotency_conflict", 409)
        return receipt

    @staticmethod
    def _next_assignee(task: ChoreTask, members: HouseholdMembers) -> str:
        current_index = task.member_order.index(task.assignee_id)
        candidates = (
            task.member_order[current_index + 1 :]
            + task.member_order[: current_index + 1]
        )
        candidates += tuple(
            item for item in members.ids if item not in task.member_order
        )
        return next(item for item in candidates if item in members.ids)

    def complete(
        self,
        actor: Principal,
        task_id: str,
        *,
        core_id: str,
        home_id: str,
        expected_revision: int,
        command_id: str,
        completed_at: float,
        members: HouseholdMembers,
    ) -> ChoreReceipt:
        if (
            type(expected_revision) is not int
            or expected_revision < 1
            or not _identifier(command_id)
            or not isinstance(completed_at, (int, float))
            or isinstance(completed_at, bool)
            or not math.isfinite(completed_at)
        ):
            raise ApiError("invalid_request", 400)
        with self.database.transaction() as connection:
            task = self._load(connection, task_id, core_id, home_id)
            self._assert_current(connection, task)
            replay = self._replay(connection, task, command_id, actor, "completed")
            if replay is not None:
                return replay
            if task.revision != expected_revision:
                raise ApiError("revision_conflict", 409)
            if actor.role != "admin" and (
                actor.id != task.assignee_id or actor.id not in members.ids
            ):
                raise ApiError("forbidden", 403)
            if members.revision < task.members_revision:
                raise ApiError("revision_conflict", 409)
            timezone = ZoneInfo(task.timezone_name)
            next_due = (
                datetime.fromtimestamp(completed_at, timezone)
                + timedelta(days=task.interval_days)
            ).timestamp()
            updated = ChoreTask(
                **{
                    **asdict(task),
                    "revision": task.revision + 1,
                    "assignee_id": self._next_assignee(task, members),
                    "members_revision": members.revision,
                    "member_order": members.ids,
                    "due_at": next_due,
                }
            )
            connection.execute(
                "UPDATE fair_chore_tasks SET revision=?,assignee_id=?,members_revision=?,"
                "member_order_json=?,due_at=?,updated_at=? WHERE id=? AND revision=?",
                (
                    updated.revision,
                    updated.assignee_id,
                    updated.members_revision,
                    json.dumps(updated.member_order, separators=(",", ":")),
                    updated.due_at,
                    completed_at,
                    task.id,
                    expected_revision,
                ),
            )
            if connection.execute("SELECT changes()").fetchone()[0] != 1:
                raise ApiError("revision_conflict", 409)
            return self._append(
                connection,
                task=updated,
                command_id=command_id,
                action="completed",
                actor_id=actor.id,
                occurred_at=float(completed_at),
            )

    def defer(
        self,
        actor: Principal,
        task_id: str,
        *,
        core_id: str,
        home_id: str,
        expected_revision: int,
        command_id: str,
        days: int,
    ) -> ChoreReceipt:
        if (
            type(expected_revision) is not int
            or expected_revision < 1
            or not _identifier(command_id)
            or type(days) is not int
            or not 1 <= days <= 30
        ):
            raise ApiError("invalid_request", 400)
        with self.database.transaction() as connection:
            task = self._load(connection, task_id, core_id, home_id)
            self._assert_current(connection, task)
            replay = self._replay(connection, task, command_id, actor, "deferred")
            if replay is not None:
                return replay
            if task.revision != expected_revision:
                raise ApiError("revision_conflict", 409)
            if actor.role != "admin" and actor.id != task.assignee_id:
                raise ApiError("forbidden", 403)
            timezone = ZoneInfo(task.timezone_name)
            due_at = (
                datetime.fromtimestamp(task.due_at, timezone) + timedelta(days=days)
            ).timestamp()
            updated = ChoreTask(
                **{**asdict(task), "revision": task.revision + 1, "due_at": due_at}
            )
            now = time.time()
            connection.execute(
                "UPDATE fair_chore_tasks SET revision=?,due_at=?,updated_at=? "
                "WHERE id=? AND revision=?",
                (updated.revision, due_at, now, task.id, expected_revision),
            )
            return self._append(
                connection,
                task=updated,
                command_id=command_id,
                action="deferred",
                actor_id=actor.id,
                occurred_at=now,
            )

    def _verified_history(
        self,
        connection: sqlite3.Connection,
        task_id: str,
    ) -> tuple[ChoreEvent, ...]:
        rows = connection.execute(
            "SELECT * FROM fair_chore_events WHERE task_id=? ORDER BY sequence",
            (task_id,),
        ).fetchall()
        previous = ""
        events: list[ChoreEvent] = []
        for row in rows:
            values = (
                row["sequence"],
                row["event_id"],
                row["task_id"],
                row["command_id"],
                row["action"],
                row["actor_id"],
                row["revision"],
                row["occurred_at"],
                row["receipt_json"],
                row["previous_hash"],
            )
            if row["previous_hash"] != previous or not hmac.compare_digest(
                row["event_hash"], self._event_hash(values)
            ):
                raise StartupError("fair_chore_history_invalid")
            receipt = self._receipt(row["receipt_json"])
            if (
                receipt.event_id != row["event_id"]
                or receipt.action != row["action"]
                or receipt.task.id != task_id
                or receipt.task.revision != row["revision"]
            ):
                raise StartupError("fair_chore_history_invalid")
            events.append(
                ChoreEvent(
                    row["event_id"],
                    row["action"],
                    row["actor_id"],
                    row["revision"],
                    row["occurred_at"],
                )
            )
            previous = row["event_hash"]
        return tuple(events)

    def history(
        self,
        actor: Principal,
        task_id: str,
        *,
        core_id: str,
        home_id: str,
    ) -> tuple[ChoreEvent, ...]:
        with self.database.connection() as connection:
            task = self._load(connection, task_id, core_id, home_id)
            events = self._verified_history(connection, task.id)
            self._authorize_read(actor, task)
            return events
