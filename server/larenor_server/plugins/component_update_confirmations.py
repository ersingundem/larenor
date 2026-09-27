"""Durable exact-review confirmations for managed component updates."""

import hashlib
import hmac
import json
import math
import sqlite3
import uuid

from ..errors import ApiError, StartupError
from .component_updates import (
    ComponentReleasePreference,
    ComponentUpdateCommand,
    ComponentUpdateError,
    ComponentUpdateReview,
    ConfirmComponentUpdateRequest,
    InstalledComponentUpdateSource,
    build_update_command,
    verify_update_command,
)


TABLE = """CREATE TABLE component_update_confirmations (
    update_id TEXT PRIMARY KEY CHECK(length(update_id)=32),
    installation_id TEXT NOT NULL CHECK(length(installation_id)=32),
    service_id TEXT NOT NULL,
    issued_at REAL NOT NULL,
    expires_at REAL NOT NULL,
    command_json TEXT NOT NULL,
    authentication_tag TEXT NOT NULL)"""
INDEX = """CREATE INDEX component_update_confirmations_installation
    ON component_update_confirmations(installation_id,expires_at)"""


def migrate_component_update_confirmations(connection: sqlite3.Connection) -> None:
    try:
        marker = connection.execute(
            "SELECT value FROM metadata "
            "WHERE key='component_update_confirmations_schema'"
        ).fetchone()
        rows = connection.execute(
            "SELECT name,type,tbl_name,sql FROM sqlite_master "
            "WHERE name IN "
            "('component_update_confirmations',"
            "'component_update_confirmations_installation') "
            "OR tbl_name='component_update_confirmations'"
        ).fetchall()
        actual = {
            row["name"]: row
            for row in rows
            if not (row["type"] == "index" and row["sql"] is None)
        }
        implicit = [
            row for row in rows if row["type"] == "index" and row["sql"] is None
        ]
        if marker is None:
            if actual or implicit:
                raise ValueError("unmarked_component_update_confirmations")
            connection.execute(TABLE)
            connection.execute(INDEX)
            connection.execute(
                "INSERT INTO metadata VALUES"
                "('component_update_confirmations_schema','1')"
            )
            return
        if (
            marker["value"] != "1"
            or set(actual)
            != {
                "component_update_confirmations",
                "component_update_confirmations_installation",
            }
            or " ".join(
                actual["component_update_confirmations"]["sql"].split()
            )
            != " ".join(TABLE.split())
            or " ".join(
                actual["component_update_confirmations_installation"]["sql"].split()
            )
            != " ".join(INDEX.split())
            or len(implicit) != 1
        ):
            raise ValueError("invalid_component_update_confirmations")
    except (ValueError, TypeError, sqlite3.Error):
        raise StartupError("component_update_confirmations_storage_invalid") from None


class ComponentUpdateConfirmationStore:
    def __init__(self, db, auth, settings, key, context):
        self.db, self.auth, self.settings, self._key = db, auth, settings, key
        self.context = context

    def _admin(self, connection, actor):
        self.auth.assert_current(connection, actor)
        if actor.role != "admin" or actor.must_change_password:
            raise ApiError("forbidden", 403)

    def _tag(self, row):
        payload = json.dumps(
            [
                self.context.coreId,
                self.context.homeId,
                row["update_id"],
                row["installation_id"],
                row["service_id"],
                row["issued_at"],
                row["expires_at"],
                row["command_json"],
            ],
            separators=(",", ":"),
            ensure_ascii=True,
            allow_nan=False,
        ).encode("ascii")
        return hmac.new(
            self._key,
            b"larenor-component-update-confirmation-v1\0" + payload,
            hashlib.sha256,
        ).hexdigest()

    def _validate(self, row):
        try:
            if (
                type(row["update_id"]) is not str
                or len(row["update_id"]) != 32
                or type(row["installation_id"]) is not str
                or len(row["installation_id"]) != 32
                or type(row["service_id"]) is not str
                or type(row["issued_at"]) is not float
                or type(row["expires_at"]) is not float
                or not math.isfinite(row["issued_at"])
                or not math.isfinite(row["expires_at"])
                or not row["issued_at"] < row["expires_at"]
                or row["expires_at"] - row["issued_at"] > 5 * 60
                or type(row["command_json"]) is not str
                or len(row["command_json"].encode("utf-8")) > 131072
                or type(row["authentication_tag"]) is not str
                or not hmac.compare_digest(
                    row["authentication_tag"], self._tag(row)
                )
            ):
                raise ValueError("invalid_component_update_confirmation")
            command = verify_update_command(
                ComponentUpdateCommand.model_validate_json(row["command_json"])
            )
            if (
                command.updateId != row["update_id"]
                or command.installationId != row["installation_id"]
                or command.serviceId != row["service_id"]
                or command.issuedAtMs != int(row["issued_at"] * 1000)
                or command.expiresAtMs != int(row["expires_at"] * 1000)
            ):
                raise ValueError("invalid_component_update_confirmation")
            return command
        except (ComponentUpdateError, ValueError, TypeError, AttributeError):
            raise ValueError("invalid_component_update_confirmation") from None

    def confirm(
        self,
        actor,
        source: InstalledComponentUpdateSource,
        review: ComponentUpdateReview,
        preference: ComponentReleasePreference,
        request: ConfirmComponentUpdateRequest,
    ) -> ComponentUpdateCommand:
        self.auth.rate_limit([("component_update_confirm", actor.id, 12)])
        now = float(self.settings.clock())
        if not math.isfinite(now) or now < 0 or now > (2**63 - 1) / 1000 - 300:
            raise ApiError("component_update_unavailable", 503)
        try:
            command = build_update_command(
                context=self.context,
                update_id=uuid.uuid4().hex,
                issued_at_ms=int(now * 1000),
                source=source,
                review=review,
                preference=preference,
                request=request,
            )
            row = {
                "update_id": command.updateId,
                "installation_id": command.installationId,
                "service_id": command.serviceId,
                "issued_at": command.issuedAtMs / 1000.0,
                "expires_at": command.expiresAtMs / 1000.0,
                "command_json": command.model_dump_json(),
            }
            row["authentication_tag"] = self._tag(row)
            with self.db.transaction() as connection:
                self._admin(connection, actor)
                active = connection.execute(
                    "SELECT * FROM component_update_confirmations "
                    "WHERE installation_id=? AND expires_at>? "
                    "ORDER BY expires_at DESC LIMIT 2",
                    (command.installationId, now),
                ).fetchall()
                if len(active) > 1:
                    raise ValueError("component_update_confirmation_limit")
                if active:
                    self._validate(active[0])
                    raise ApiError("component_update_already_confirmed", 409)
                count = connection.execute(
                    "SELECT count(*) FROM component_update_confirmations"
                ).fetchone()[0]
                if type(count) is not int or count >= 1024:
                    raise ApiError("component_update_confirmation_limit", 429)
                connection.execute(
                    "INSERT INTO component_update_confirmations "
                    "VALUES(?,?,?,?,?,?,?)",
                    tuple(row.values()),
                )
            return command
        except ApiError:
            raise
        except ComponentUpdateError:
            raise ApiError("component_update_conflict", 409) from None
        except (ValueError, TypeError, sqlite3.Error, OverflowError):
            raise ApiError("component_update_unavailable", 503) from None

    def validate_storage(self):
        try:
            with self.db.connection() as connection:
                rows = connection.execute(
                    "SELECT * FROM component_update_confirmations "
                    "ORDER BY issued_at DESC LIMIT 1025"
                ).fetchall()
                if len(rows) > 1024:
                    raise ValueError("component_update_confirmation_limit")
                active = set()
                now = float(self.settings.clock())
                for row in rows:
                    command = self._validate(row)
                    if row["expires_at"] > now:
                        if command.installationId in active:
                            raise ValueError("duplicate_component_update_confirmation")
                        active.add(command.installationId)
        except (ValueError, TypeError, sqlite3.Error, OverflowError):
            raise StartupError(
                "component_update_confirmations_storage_invalid"
            ) from None

    def discard_unvalidated(self, command: ComponentUpdateCommand) -> None:
        """Remove only the exact command rejected by the isolated worker."""
        try:
            command = verify_update_command(command)
            with self.db.transaction() as connection:
                rows = connection.execute(
                    "SELECT * FROM component_update_confirmations "
                    "WHERE update_id=? AND installation_id=? LIMIT 2",
                    (command.updateId, command.installationId),
                ).fetchall()
                if len(rows) != 1 or self._validate(rows[0]) != command:
                    raise ValueError("component_update_confirmation_mismatch")
                connection.execute(
                    "DELETE FROM component_update_confirmations WHERE update_id=?",
                    (command.updateId,),
                )
        except (ComponentUpdateError, ValueError, TypeError, sqlite3.Error):
            raise ApiError("component_update_unavailable", 503) from None
