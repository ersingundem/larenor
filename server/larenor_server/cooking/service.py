from dataclasses import dataclass
import json
import sqlite3
import time
import uuid

from ..auth import Principal
from ..database import Database
from ..errors import ApiError


MAX_STEPS = 100
MAX_STEP_LENGTH = 2000
MAX_TITLE_LENGTH = 200
MAX_SESSIONS_PER_ACCOUNT = 100


@dataclass(frozen=True)
class CookingSession:
    id: str
    account_id: str
    recipe_id: str
    recipe_revision: int
    revision: int
    title: str
    steps: tuple[str, ...]
    current_step: int


class CookingSessionStore:
    """Durable recipe snapshot state owned by one authenticated account.

    A recipe update never mutates an active session. Starting a new session is
    the only way to adopt a different recipe revision.
    """

    def __init__(self, database: Database):
        self.database = database

    @staticmethod
    def _identifier(value: str) -> bool:
        return isinstance(value, str) and 1 <= len(value) <= 128 and all(
            char.isalnum() or char in "-_.:" for char in value
        )

    @staticmethod
    def _decode(row: sqlite3.Row) -> CookingSession:
        try:
            steps = json.loads(row["steps_json"])
            if not isinstance(steps, list) or not all(isinstance(step, str) for step in steps):
                raise ValueError
            return CookingSession(
                id=row["id"], account_id=row["account_id"],
                recipe_id=row["recipe_id"], recipe_revision=row["recipe_revision"],
                revision=row["revision"], title=row["title"], steps=tuple(steps),
                current_step=row["current_step"],
            )
        except (KeyError, TypeError, ValueError, json.JSONDecodeError):
            raise ApiError("server_unavailable", 503) from None

    def create(
        self,
        actor: Principal,
        *,
        recipe_id: str,
        recipe_revision: int,
        title: str,
        steps: tuple[str, ...],
    ) -> CookingSession:
        if (
            not self._identifier(recipe_id)
            or type(recipe_revision) is not int
            or recipe_revision < 1
            or not isinstance(title, str)
            or not 1 <= len(title.strip()) <= MAX_TITLE_LENGTH
            or not isinstance(steps, tuple)
            or not 1 <= len(steps) <= MAX_STEPS
            or any(not isinstance(step, str) or not 1 <= len(step.strip()) <= MAX_STEP_LENGTH for step in steps)
        ):
            raise ApiError("invalid_request", 400)
        normalized = tuple(step.strip() for step in steps)
        identifier = uuid.uuid4().hex
        with self.database.transaction() as connection:
            count = connection.execute(
                "SELECT COUNT(*) FROM cooking_sessions WHERE account_id=?",
                (actor.id,),
            ).fetchone()[0]
            if count >= MAX_SESSIONS_PER_ACCOUNT:
                raise ApiError("cooking_session_limit_reached", 413)
            now = time.time()
            connection.execute(
                "INSERT INTO cooking_sessions VALUES(?,?,?,?,?,?,?,?,?,?)",
                (identifier, actor.id, recipe_id, recipe_revision, 1, title.strip(),
                 json.dumps(normalized, ensure_ascii=False, separators=(",", ":")),
                 0, now, now),
            )
            row = connection.execute(
                "SELECT * FROM cooking_sessions WHERE id=?", (identifier,)
            ).fetchone()
        return self._decode(row)

    def get(self, actor: Principal, session_id: str) -> CookingSession:
        if not self._identifier(session_id):
            raise ApiError("not_found", 404)
        with self.database.connection() as connection:
            row = connection.execute(
                "SELECT * FROM cooking_sessions WHERE id=? AND account_id=?",
                (session_id, actor.id),
            ).fetchone()
        if row is None:
            raise ApiError("not_found", 404)
        return self._decode(row)

    def move(
        self,
        actor: Principal,
        session_id: str,
        *,
        expected_revision: int,
        step: int,
    ) -> CookingSession:
        if (
            not self._identifier(session_id)
            or type(expected_revision) is not int
            or expected_revision < 1
            or type(step) is not int
            or step < 0
        ):
            raise ApiError("invalid_request", 400)
        with self.database.transaction() as connection:
            row = connection.execute(
                "SELECT * FROM cooking_sessions WHERE id=? AND account_id=?",
                (session_id, actor.id),
            ).fetchone()
            if row is None:
                raise ApiError("not_found", 404)
            current = self._decode(row)
            if current.revision != expected_revision:
                raise ApiError("revision_conflict", 409)
            if step >= len(current.steps):
                raise ApiError("invalid_request", 400)
            connection.execute(
                "UPDATE cooking_sessions SET current_step=?,revision=revision+1,updated_at=? "
                "WHERE id=? AND account_id=? AND revision=?",
                (step, time.time(), session_id, actor.id, expected_revision),
            )
            changed = connection.execute("SELECT changes()").fetchone()[0]
            if changed != 1:
                raise ApiError("revision_conflict", 409)
            updated = connection.execute(
                "SELECT * FROM cooking_sessions WHERE id=?", (session_id,)
            ).fetchone()
        return self._decode(updated)
