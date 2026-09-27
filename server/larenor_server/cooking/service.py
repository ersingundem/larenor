from dataclasses import dataclass
import hashlib
import json
import sqlite3
import time
import uuid

from ..auth import Principal
from ..database import Database
from ..errors import ApiError
from ..pantry_stock.ledger import PantryConflict
from ..pantry_stock.models import StockAmount


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
    cancelled_at: float | None = None

    def contract(self) -> dict:
        return {
            "schemaVersion": 1,
            "id": self.id,
            "accountId": self.account_id,
            "recipeId": self.recipe_id,
            "recipeRevision": self.recipe_revision,
            "revision": self.revision,
            "title": self.title,
            "steps": self.steps,
            "currentStep": self.current_step,
            "cancelled": self.cancelled_at is not None,
        }


class CookingSessionStore:
    """Durable recipe snapshot state owned by one authenticated account.

    A recipe update never mutates an active session. Starting a new session is
    the only way to adopt a different recipe revision.
    """

    def __init__(self, database: Database, pantry_stock=None):
        self.database = database
        self.pantry_stock = pantry_stock

    @staticmethod
    def _identifier(value: str) -> bool:
        return isinstance(value, str) and 1 <= len(value) <= 128 and all(
            char.isalnum() or char in "-_.:" for char in value
        )

    @staticmethod
    def _decode(row: sqlite3.Row) -> CookingSession:
        try:
            steps = json.loads(row["steps_json"])
            if (
                not isinstance(steps, list)
                or not 1 <= len(steps) <= MAX_STEPS
                or not all(
                    isinstance(step, str)
                    and 1 <= len(step) <= MAX_STEP_LENGTH
                    and step == step.strip()
                    for step in steps
                )
                or type(row["current_step"]) is not int
                or not 0 <= row["current_step"] < len(steps)
                or type(row["revision"]) is not int
                or row["revision"] < 1
                or type(row["recipe_revision"]) is not int
                or row["recipe_revision"] < 1
                or not CookingSessionStore._identifier(row["id"])
                or not CookingSessionStore._identifier(row["account_id"])
                or not CookingSessionStore._identifier(row["recipe_id"])
                or not isinstance(row["title"], str)
                or not 1 <= len(row["title"]) <= MAX_TITLE_LENGTH
                or row["title"] != row["title"].strip()
                or (
                    row["cancelled_at"] is not None
                    and not isinstance(row["cancelled_at"], (int, float))
                )
            ):
                raise ValueError
            return CookingSession(
                id=row["id"], account_id=row["account_id"],
                recipe_id=row["recipe_id"], recipe_revision=row["recipe_revision"],
                revision=row["revision"], title=row["title"], steps=tuple(steps),
                current_step=row["current_step"],
                cancelled_at=row["cancelled_at"],
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
                "INSERT INTO cooking_sessions VALUES(?,?,?,?,?,?,?,?,?,?,?)",
                (identifier, actor.id, recipe_id, recipe_revision, 1, title.strip(),
                 json.dumps(normalized, ensure_ascii=False, separators=(",", ":")),
                 0, None, now, now),
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

    def list(self, actor: Principal) -> tuple[CookingSession, ...]:
        with self.database.connection() as connection:
            rows = connection.execute(
                "SELECT * FROM cooking_sessions WHERE account_id=? "
                "ORDER BY updated_at DESC,id LIMIT ?",
                (actor.id, MAX_SESSIONS_PER_ACCOUNT),
            ).fetchall()
        return tuple(self._decode(row) for row in rows)

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
            if current.cancelled_at is not None:
                raise ApiError("cooking_session_cancelled", 409)
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

    def cancel(
        self,
        actor: Principal,
        session_id: str,
        *,
        expected_revision: int,
    ) -> CookingSession:
        if (
            not self._identifier(session_id)
            or type(expected_revision) is not int
            or expected_revision < 1
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
            if current.cancelled_at is not None:
                return current
            if current.revision != expected_revision:
                raise ApiError("revision_conflict", 409)
            now = time.time()
            changed = connection.execute(
                "UPDATE cooking_sessions SET cancelled_at=?,revision=revision+1,"
                "updated_at=? WHERE id=? AND account_id=? AND revision=? "
                "AND cancelled_at IS NULL",
                (now, now, session_id, actor.id, expected_revision),
            ).rowcount
            if changed != 1:
                raise ApiError("revision_conflict", 409)
            updated = connection.execute(
                "SELECT * FROM cooking_sessions WHERE id=?", (session_id,)
            ).fetchone()
        return self._decode(updated)

    @staticmethod
    def _deduction_key(actor: Principal, session_id: str, body) -> str:
        canonical = json.dumps(
            [
                "larenor-ingredient-deduction-v1",
                actor.id,
                session_id,
                body.recipeRevision,
                body.completedStep,
                body.stepRevision,
                body.expectedPantryRevision,
                [
                    [item.stockItemId, item.quantityMicros, item.unit]
                    for item in body.items
                ],
            ],
            ensure_ascii=False,
            separators=(",", ":"),
        ).encode("utf-8")
        return hashlib.sha256(canonical).hexdigest()

    def deduct_ingredients(
        self,
        actor: Principal,
        session_id: str,
        core_id: str,
        home_id: str,
        body,
    ) -> dict:
        pantry = self.pantry_stock
        if pantry is None:
            raise ApiError("server_unavailable", 503)
        if not self._identifier(session_id):
            raise ApiError("not_found", 404)
        if body.idempotencyKey != self._deduction_key(actor, session_id, body):
            raise ApiError("idempotency_conflict", 409)
        if tuple(item.stockItemId for item in body.items) != tuple(
            sorted(item.stockItemId for item in body.items)
        ):
            raise ApiError("invalid_request", 400)
        pantry._scope(core_id, home_id)
        pantry.auth.rate_limit([("cooking_ingredient_deduction", actor.id, 60)])
        try:
            with self.database.transaction() as connection:
                pantry.auth.assert_current(connection, actor)
                existing = connection.execute(
                    "SELECT account_id,session_id,receipt_json "
                    "FROM cooking_deductions WHERE idempotency_key=?",
                    (body.idempotencyKey,),
                ).fetchone()
                if existing is not None:
                    if (
                        existing["account_id"] != actor.id
                        or existing["session_id"] != session_id
                    ):
                        raise ApiError("idempotency_conflict", 409)
                    return json.loads(existing["receipt_json"])
                session_row = connection.execute(
                    "SELECT * FROM cooking_sessions WHERE id=? AND account_id=?",
                    (session_id, actor.id),
                ).fetchone()
                if session_row is None:
                    raise ApiError("not_found", 404)
                session = self._decode(session_row)
                if session.cancelled_at is not None:
                    raise ApiError("cooking_session_cancelled", 409)
                if (
                    session.recipe_revision != body.recipeRevision
                    or session.current_step != body.completedStep
                    or session.revision != body.stepRevision
                ):
                    raise ApiError("revision_conflict", 409)
                count = connection.execute(
                    "SELECT COUNT(*) FROM cooking_deductions WHERE account_id=?",
                    (actor.id,),
                ).fetchone()[0]
                if count >= 4096:
                    raise ApiError("receipt_capacity", 409)
                ledger = pantry._read(connection)
                if ledger.snapshot().revision != body.expectedPantryRevision:
                    raise ApiError("revision_conflict", 409)
                for index, item in enumerate(body.items):
                    request_id = hashlib.sha256(
                        f"larenor-f33-deduction-v1\0{body.idempotencyKey}\0{index}".encode(
                            "ascii"
                        )
                    ).hexdigest()[:32]
                    ledger.consume(
                        request_id=request_id,
                        expected_revision=body.expectedPantryRevision + index,
                        ingredient_key=item.stockItemId,
                        amount=StockAmount(
                            schemaVersion=1,
                            quantityMillis=item.quantityMicros,
                            unit=item.unit,
                        ),
                    )
                pantry._save(connection, ledger)
                response = {
                    "schemaVersion": 1,
                    "receipt": {
                        "schemaVersion": 1,
                        "idempotencyKey": body.idempotencyKey,
                        "accountId": actor.id,
                        "pantryRevision": body.expectedPantryRevision
                        + len(body.items),
                        "applied": [
                            item.model_dump(mode="json") for item in body.items
                        ],
                    },
                }
                connection.execute(
                    "INSERT INTO cooking_deductions VALUES(?,?,?,?,?)",
                    (
                        body.idempotencyKey,
                        actor.id,
                        session_id,
                        json.dumps(
                            response,
                            ensure_ascii=False,
                            separators=(",", ":"),
                        ),
                        time.time(),
                    ),
                )
                return response
        except PantryConflict as error:
            status = 400 if error.code == "invalid_request" else 409
            raise ApiError(error.code, status) from None

    def ingredient_receipt(
        self,
        actor: Principal,
        session_id: str,
        idempotency_key: str,
        core_id: str,
        home_id: str,
    ) -> dict:
        if (
            not self._identifier(session_id)
            or len(idempotency_key) != 64
            or any(char not in "0123456789abcdef" for char in idempotency_key)
        ):
            raise ApiError("not_found", 404)
        pantry = self.pantry_stock
        if pantry is None:
            raise ApiError("server_unavailable", 503)
        pantry._scope(core_id, home_id)
        pantry.auth.rate_limit([("cooking_ingredient_receipt", actor.id, 120)])
        with self.database.connection() as connection:
            pantry.auth.assert_current(connection, actor)
            row = connection.execute(
                "SELECT receipt_json FROM cooking_deductions "
                "WHERE idempotency_key=? AND account_id=? AND session_id=?",
                (idempotency_key, actor.id, session_id),
            ).fetchone()
        if row is None:
            raise ApiError("not_found", 404)
        try:
            return json.loads(row["receipt_json"])
        except (json.JSONDecodeError, TypeError):
            raise ApiError("server_unavailable", 503) from None
