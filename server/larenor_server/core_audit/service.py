"""Authenticated verification service for the Core-wide audit journal."""

from __future__ import annotations

import sqlite3

from ..errors import ApiError
from .journal import checkpoint


class CoreAuditService:
    def __init__(self, db, auth, key: bytes, scope):
        self.db, self.auth = db, auth
        self._key, self.scope = key, scope

    def verification(
        self,
        actor,
        core_id: str,
        home_id: str,
        *,
        expected_checkpoint: str | None = None,
    ) -> dict:
        if (core_id, home_id) != (self.scope.coreId, self.scope.homeId):
            raise ApiError("not_found", 404)
        try:
            with self.db.connection() as connection:
                connection.execute("BEGIN")
                self.auth.assert_current(connection, actor)
                if actor.must_change_password:
                    raise ApiError("password_change_required", 403)
                if actor.role != "admin":
                    raise ApiError("forbidden", 403)
                return {
                    "verification": checkpoint(
                        connection,
                        self._key,
                        self.scope,
                        expected_checkpoint,
                    )
                }
        except ApiError:
            raise
        except (OverflowError, TypeError, ValueError, sqlite3.Error):
            raise ApiError("core_audit_integrity_failed", 503) from None
