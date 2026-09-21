"""Authenticated integration for the encrypted family-board reducer."""

import hashlib
from pathlib import Path

from ..errors import ApiError
from .models import BoardAuthority, BoardDelta, BoardSnapshot
from .store import FamilyBoardStore, ZERO_HASH


class FamilyBoardService:
    """Bind the isolated reducer to the current Core account and session."""

    def __init__(self, db, auth, settings, key, context):
        self.db, self.auth, self.settings = db, auth, settings
        self.key, self.context = key, context
        self.path = Path(settings.data_dir) / "family-board.sqlite3"
        # Startup validates the complete encrypted store before serving traffic.
        FamilyBoardStore(self.path, key, lambda _account_id: None, clock=settings.clock)

    def _scope(self, core_id, home_id):
        if (core_id, home_id) != (self.context.coreId, self.context.homeId):
            raise ApiError("not_found", 404)

    def _default_board_id(self):
        payload = (
            f"larenor-family-board-v1:{self.context.coreId}:{self.context.homeId}"
        ).encode("ascii")
        return hashlib.sha256(payload).hexdigest()[:32]

    def _authority(self, actor, core_id, home_id, board_id=None):
        self._scope(core_id, home_id)
        expected_board = self._default_board_id()
        if board_id is not None and board_id != expected_board:
            raise ApiError("not_found", 404)
        with self.db.connection() as connection:
            self.auth.assert_current(connection, actor)
            row = connection.execute(
                "SELECT revision,role,disabled,must_change_password "
                "FROM users WHERE id=?",
                (actor.id,),
            ).fetchone()
        if row is None or row["disabled"] or row["must_change_password"]:
            raise ApiError("invalid_session", 401)
        if row["role"] != actor.role:
            raise ApiError("invalid_session", 401)
        return BoardAuthority(
            schemaVersion=1,
            coreId=self.context.coreId,
            homeId=self.context.homeId,
            homeRevision=1,
            boardId=expected_board,
            accountId=actor.id,
            accountRevision=row["revision"],
            memberRevision=row["revision"],
            sessionFamilyId=actor.family_id,
            role=actor.role,
            canRead=True,
            canWrite=True,
            active=True,
        )

    def authority(self, actor, core_id, home_id):
        return self._authority(actor, core_id, home_id)

    def _store(self, actor, current):
        def resolve(account_id):
            if account_id != actor.id:
                return None
            return self._authority(
                actor,
                current.coreId,
                current.homeId,
                current.boardId,
            )

        return FamilyBoardStore(
            self.path,
            self.key,
            resolve,
            clock=self.settings.clock,
        )

    @staticmethod
    def _expect(current, body):
        if (
            body.expectedHomeRevision != current.homeRevision
            or body.expectedAccountRevision != current.accountRevision
            or body.expectedMemberRevision != current.memberRevision
            or body.expectedSessionFamilyId != current.sessionFamilyId
        ):
            raise ApiError("revision_conflict", 409)

    def snapshot(self, actor, core_id, home_id, board_id):
        current = self._authority(actor, core_id, home_id, board_id)
        store = self._store(actor, current)
        try:
            return store.snapshot(current)
        except ApiError as error:
            if error.code != "not_found":
                raise
            # A new board is a real revision-zero resource. Its first append is
            # still committed atomically by the reducer.
            return BoardSnapshot(
                schemaVersion=1,
                authority=current,
                boardRevision=0,
                auditHead=ZERO_HASH,
                elements=[],
            )

    def delta(self, actor, core_id, home_id, board_id, body):
        current = self._authority(actor, core_id, home_id, board_id)
        self._expect(current, body)
        try:
            return self._store(actor, current).delta(
                current,
                after_sequence=body.afterSequence,
                limit=body.limit,
            )
        except ApiError as error:
            if error.code != "not_found" or body.afterSequence != 0:
                raise
            return BoardDelta(
                schemaVersion=1,
                coreId=current.coreId,
                homeId=current.homeId,
                boardId=current.boardId,
                boardRevision=0,
                afterSequence=0,
                nextAfter=0,
                auditHead=ZERO_HASH,
                events=[],
            )

    def apply(self, actor, core_id, home_id, board_id, body):
        current = self._authority(actor, core_id, home_id, board_id)
        self._expect(current, body)
        return self._store(actor, current).apply(current, body.command())
