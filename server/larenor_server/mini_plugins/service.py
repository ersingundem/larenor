import hashlib
import hmac
import json
import sqlite3
import uuid

from ..errors import ApiError, StartupError
from .models import CreateMiniPlugin, RenderMiniPlugin, StopMiniPlugin


MAX_INSTANCES = 64
MAX_RUNNING = 8
CAPABILITIES = ["home.resource_count.read"]
LIMITS = {
    "filesystem": {
        "mode": "none",
        "scratchBytes": 0,
        "hostPathsAvailable": False,
    },
    "network": {
        "mode": "deny_all",
        "allowedDestinations": [],
    },
    "output": {"maxBytesPerInvocation": 1024},
}
DENIALS = {
    "crossHomeAccess": False,
    "secretsAvailable": False,
    "hostManagementAvailable": False,
    "arbitraryCodeAvailable": False,
}


class MiniPluginService:
    def __init__(self, resources, settings, key):
        self.resources, self.settings = resources, settings
        self.db, self.auth = resources.db, resources.auth
        self._key = hmac.new(
            key, b"larenor-mini-plugins-v1", hashlib.sha256
        ).digest()

    def _tag(self, row):
        values = [
            row[name]
            for name in (
                "id",
                "creator_id",
                "family_id",
                "request_key",
                "core_id",
                "home_id",
                "template_id",
                "display_name",
                "revision",
                "state",
                "created_at",
                "updated_at",
            )
        ]
        return hmac.new(
            self._key,
            json.dumps(values, separators=(",", ":"), ensure_ascii=True).encode(
                "ascii"
            ),
            hashlib.sha256,
        ).hexdigest()

    def _verified(self, row):
        if row is None:
            raise ApiError("not_found", 404)
        if not hmac.compare_digest(row["record_tag"], self._tag(row)):
            raise StartupError("mini_plugin_storage_invalid")
        return row

    def _validate(self, connection):
        rows = connection.execute(
            "SELECT * FROM mini_plugin_instances ORDER BY id LIMIT ?",
            (MAX_INSTANCES + 1,),
        ).fetchall()
        if len(rows) > MAX_INSTANCES:
            raise StartupError("mini_plugin_storage_invalid")
        running = 0
        for row in rows:
            self._verified(row)
            if (row["core_id"], row["home_id"]) != (
                self.resources.scope.coreId,
                self.resources.scope.homeId,
            ):
                raise StartupError("mini_plugin_storage_invalid")
            running += row["state"] == "running"
        if running > MAX_RUNNING:
            raise StartupError("mini_plugin_storage_invalid")
        return rows

    def validate_storage(self):
        try:
            with self.db.connection() as connection:
                self._validate(connection)
        except StartupError:
            raise
        except (sqlite3.Error, TypeError, ValueError):
            raise StartupError("mini_plugin_storage_invalid") from None

    @staticmethod
    def catalog():
        return {
            "schemaVersion": 2,
            "catalogVersion": "mini-plugin-catalog-v2",
            "templates": [
                {
                    "schemaVersion": 2,
                    "id": "home-resource-count",
                    "displayName": "Home resource count",
                    "executionClass": "builtin_metadata_v2",
                    "capabilities": CAPABILITIES,
                    "limits": LIMITS,
                    "denials": DENIALS,
                    "operations": ["render", "stop"],
                }
            ],
        }

    @staticmethod
    def _public(row):
        return {
            "schemaVersion": 2,
            "id": row["id"],
            "revision": row["revision"],
            "templateId": row["template_id"],
            "displayName": row["display_name"],
            "state": row["state"],
            "executionClass": "builtin_metadata_v2",
            "capabilities": CAPABILITIES,
            "limits": LIMITS,
            "denials": DENIALS,
            "createdAt": row["created_at"],
            "updatedAt": row["updated_at"],
        }

    def list(self, actor, core_id, home_id):
        with self.resources._transaction(actor, core_id, home_id, admin=True) as (
            connection,
            _facts,
        ):
            rows = self._validate(connection)
            return {
                "schemaVersion": 2,
                "instances": [self._public(row) for row in rows],
                "maximumInstances": MAX_INSTANCES,
                "maximumRunning": MAX_RUNNING,
            }

    def create(self, actor, core_id, home_id, body):
        body = CreateMiniPlugin.model_validate(body)
        now = float(self.settings.clock())
        with self.resources._transaction(actor, core_id, home_id, admin=True) as (
            connection,
            _facts,
        ):
            rows = self._validate(connection)
            existing = connection.execute(
                "SELECT * FROM mini_plugin_instances WHERE creator_id=? "
                "AND family_id=? AND request_key=?",
                (actor.id, actor.family_id, body.requestKey),
            ).fetchone()
            if existing is not None:
                existing = self._verified(existing)
                if (
                    existing["template_id"],
                    existing["display_name"],
                ) != (body.templateId, body.displayName):
                    raise ApiError("idempotency_conflict", 409)
                return {"instance": self._public(existing)}
            if len(rows) >= MAX_INSTANCES:
                raise ApiError("mini_plugin_limit_reached", 429)
            if sum(row["state"] == "running" for row in rows) >= MAX_RUNNING:
                raise ApiError("mini_plugin_running_limit_reached", 429)
            row = {
                "id": uuid.uuid4().hex,
                "creator_id": actor.id,
                "family_id": actor.family_id,
                "request_key": body.requestKey,
                "core_id": core_id,
                "home_id": home_id,
                "template_id": body.templateId,
                "display_name": body.displayName,
                "revision": 1,
                "state": "running",
                "created_at": now,
                "updated_at": now,
            }
            connection.execute(
                "INSERT INTO mini_plugin_instances VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)",
                (*row.values(), self._tag(row)),
            )
            return {"instance": self._public(self._verified(connection.execute(
                "SELECT * FROM mini_plugin_instances WHERE id=?", (row["id"],)
            ).fetchone()))}

    def stop(self, actor, core_id, home_id, plugin_id, body):
        body = StopMiniPlugin.model_validate(body)
        now = float(self.settings.clock())
        with self.resources._transaction(actor, core_id, home_id, admin=True) as (
            connection,
            _facts,
        ):
            self._validate(connection)
            row = self._verified(connection.execute(
                "SELECT * FROM mini_plugin_instances WHERE id=?", (plugin_id,)
            ).fetchone())
            if row["state"] == "stopped":
                return {"instance": self._public(row)}
            if row["revision"] != body.expectedRevision:
                raise ApiError("mini_plugin_changed", 409)
            updated = dict(row)
            updated.update(
                revision=row["revision"] + 1,
                state="stopped",
                updated_at=now,
            )
            updated["record_tag"] = self._tag(updated)
            connection.execute(
                "UPDATE mini_plugin_instances SET revision=?,state=?,updated_at=?,"
                "record_tag=? WHERE id=?",
                (
                    updated["revision"],
                    updated["state"],
                    updated["updated_at"],
                    updated["record_tag"],
                    plugin_id,
                ),
            )
            return {"instance": self._public(updated)}

    def render(self, actor, core_id, home_id, plugin_id, body):
        body = RenderMiniPlugin.model_validate(body)
        with self.resources._transaction(actor, core_id, home_id, admin=True) as (
            connection,
            _facts,
        ):
            self._validate(connection)
            row = self._verified(connection.execute(
                "SELECT * FROM mini_plugin_instances WHERE id=?", (plugin_id,)
            ).fetchone())
            if row["revision"] != body.expectedRevision:
                raise ApiError("mini_plugin_changed", 409)
            if row["state"] != "running":
                raise ApiError("mini_plugin_stopped", 409)
            state = self.resources._state(connection)
            result = {
                "schemaVersion": 2,
                "pluginId": row["id"],
                "pluginRevision": row["revision"],
                "capability": "home.resource_count.read",
                "resourceCount": state["record_count"],
                "generatedAt": float(self.settings.clock()),
                "networkRequests": 0,
                "filesystemBytes": 0,
                "secretReads": 0,
                "hostOperations": 0,
                "outputBytesMaximum": LIMITS["output"]["maxBytesPerInvocation"],
            }
            if len(json.dumps(result, separators=(",", ":")).encode()) > 1024:
                raise ApiError("mini_plugin_output_limit", 413)
            return {"result": result}
