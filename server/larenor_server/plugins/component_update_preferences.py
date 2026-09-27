"""Durable admin policy for catalog-managed component releases."""

import hashlib
import hmac
import json
import math
import sqlite3

from ..errors import ApiError, StartupError
from .catalog import load_catalog
from .component_updates import (
    ComponentReleasePreference,
    PutComponentReleasePreference,
)


TABLE = """CREATE TABLE component_update_preferences (
    service_id TEXT PRIMARY KEY,
    revision INTEGER NOT NULL CHECK(revision > 0),
    mode TEXT NOT NULL CHECK(mode IN ('stable_only','manual_review','disabled')),
    require_upstream_signature INTEGER NOT NULL CHECK(require_upstream_signature IN (0,1)),
    updated_at REAL NOT NULL,
    authentication_tag TEXT NOT NULL)"""


def migrate_component_update_preferences(connection: sqlite3.Connection) -> None:
    try:
        marker = connection.execute(
            "SELECT value FROM metadata WHERE key='component_update_preferences_schema'"
        ).fetchone()
        rows = connection.execute(
            "SELECT name,type,tbl_name,sql FROM sqlite_master "
            "WHERE name='component_update_preferences' "
            "OR tbl_name='component_update_preferences'"
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
                raise ValueError("unmarked_component_update_preferences")
            connection.execute(TABLE)
            connection.execute(
                "INSERT INTO metadata VALUES('component_update_preferences_schema','1')"
            )
            return
        row = actual.get("component_update_preferences")
        if (
            marker["value"] != "1"
            or set(actual) != {"component_update_preferences"}
            or row["type"] != "table"
            or " ".join(row["sql"].split()) != " ".join(TABLE.split())
            or len(implicit) != 1
        ):
            raise ValueError("invalid_component_update_preferences")
    except (ValueError, TypeError, sqlite3.Error):
        raise StartupError("component_update_preferences_storage_invalid") from None


class ComponentUpdatePreferenceStore:
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
                row["service_id"],
                row["revision"],
                row["mode"],
                row["require_upstream_signature"],
                row["updated_at"],
            ],
            separators=(",", ":"),
            allow_nan=False,
        ).encode("ascii")
        return hmac.new(
            self._key,
            b"larenor-component-update-preference-v1\0" + payload,
            hashlib.sha256,
        ).hexdigest()

    def _public(self, service_id, row=None):
        return ComponentReleasePreference(
            schemaVersion=1,
            coreId=self.context.coreId,
            homeId=self.context.homeId,
            serviceId=service_id,
            revision=0 if row is None else row["revision"],
            mode="stable_only" if row is None else row["mode"],
            requireUpstreamSignature=(
                False if row is None else bool(row["require_upstream_signature"])
            ),
        )

    def _validate(self, row, *, service_id=None):
        if row is None:
            return None
        if (
            type(row["service_id"]) is not str
            or service_id is not None
            and row["service_id"] != service_id
            or type(row["revision"]) is not int
            or not 1 <= row["revision"] <= 2**63 - 1
            or row["mode"] not in {"stable_only", "manual_review", "disabled"}
            or row["require_upstream_signature"] not in {0, 1}
            or type(row["updated_at"]) is not float
            or not math.isfinite(row["updated_at"])
            or type(row["authentication_tag"]) is not str
            or len(row["authentication_tag"]) != 64
            or not hmac.compare_digest(row["authentication_tag"], self._tag(row))
        ):
            raise ValueError("invalid_component_update_preference")
        return self._public(row["service_id"], row)

    @staticmethod
    def _catalog_services():
        return tuple(sorted(entry.manifest.serviceId for entry in load_catalog().entries))

    def list(self, actor, service_ids):
        service_ids = tuple(service_ids)
        if (
            len(service_ids) > 6
            or len(set(service_ids)) != len(service_ids)
            or any(item not in self._catalog_services() for item in service_ids)
        ):
            raise ApiError("component_update_unavailable", 503)
        self.auth.rate_limit([("component_update_preference_read", actor.id, 240)])
        try:
            with self.db.connection() as connection:
                connection.execute("BEGIN")
                self._admin(connection, actor)
                rows = {
                    row["service_id"]: row
                    for row in connection.execute(
                        "SELECT * FROM component_update_preferences ORDER BY service_id LIMIT 7"
                    ).fetchall()
                }
                if len(rows) > 6 or any(key not in self._catalog_services() for key in rows):
                    raise ValueError("component_update_preference_limit")
                return tuple(
                    self._public(service_id, rows.get(service_id))
                    if rows.get(service_id) is None
                    else self._validate(rows[service_id], service_id=service_id)
                    for service_id in service_ids
                )
        except ApiError:
            raise
        except (ValueError, TypeError, sqlite3.Error, OverflowError):
            raise ApiError("component_update_unavailable", 503) from None

    def put(self, actor, service_id, value):
        body = PutComponentReleasePreference.model_validate(value)
        if service_id not in self._catalog_services():
            raise ApiError("not_found", 404)
        self.auth.rate_limit([("component_update_preference_write", actor.id, 30)])
        try:
            with self.db.transaction() as connection:
                self._admin(connection, actor)
                old = connection.execute(
                    "SELECT * FROM component_update_preferences WHERE service_id=?",
                    (service_id,),
                ).fetchone()
                if old is not None:
                    self._validate(old, service_id=service_id)
                revision = 0 if old is None else old["revision"]
                if revision != body.expectedRevision or revision >= 2**63 - 1:
                    raise ApiError("revision_conflict", 409)
                row = {
                    "service_id": service_id,
                    "revision": revision + 1,
                    "mode": body.mode,
                    "require_upstream_signature": int(body.requireUpstreamSignature),
                    "updated_at": float(self.settings.clock()),
                }
                row["authentication_tag"] = self._tag(row)
                connection.execute(
                    "INSERT INTO component_update_preferences VALUES(?,?,?,?,?,?) "
                    "ON CONFLICT(service_id) DO UPDATE SET "
                    "revision=excluded.revision,mode=excluded.mode,"
                    "require_upstream_signature=excluded.require_upstream_signature,"
                    "updated_at=excluded.updated_at,"
                    "authentication_tag=excluded.authentication_tag",
                    tuple(row.values()),
                )
                return self._public(service_id, row)
        except ApiError:
            raise
        except (ValueError, TypeError, sqlite3.Error, OverflowError):
            raise ApiError("component_update_unavailable", 503) from None

    def validate_storage(self):
        try:
            allowed = set(self._catalog_services())
            with self.db.connection() as connection:
                rows = connection.execute(
                    "SELECT * FROM component_update_preferences ORDER BY service_id LIMIT 7"
                ).fetchall()
                if len(rows) > 6:
                    raise ValueError("component_update_preference_limit")
                for row in rows:
                    if row["service_id"] not in allowed:
                        raise ValueError("unknown_component_update_service")
                    self._validate(row)
        except (ValueError, TypeError, sqlite3.Error, OverflowError):
            raise StartupError("component_update_preferences_storage_invalid") from None
