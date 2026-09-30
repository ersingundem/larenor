"""Private, authenticated persistence for each account's Frigate audio source."""

import hashlib
import hmac
import json
import os
import secrets
import sqlite3
from contextlib import contextmanager
from pathlib import Path

from ..errors import ApiError, StartupError
from .models import SoundSourceStatus
from .source_models import FrigateSoundSource


class SoundSourceStore:
    def __init__(self, path, key, primary_db, auth, clock):
        self.path = Path(path)
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self._key, self._primary, self._auth, self._clock = key, primary_db, auth, clock
        try:
            self._migrate()
            os.chmod(self.path, 0o600)
            self.validate_storage()
        except StartupError:
            raise
        except (OSError, sqlite3.Error, TypeError, ValueError):
            raise StartupError("sound_source_storage_invalid") from None

    @contextmanager
    def _connection(self, *, write=False):
        connection = sqlite3.connect(self.path, timeout=5, isolation_level=None)
        connection.row_factory = sqlite3.Row
        try:
            connection.execute("BEGIN IMMEDIATE" if write else "BEGIN")
            yield connection
            connection.commit()
        except BaseException:
            connection.rollback()
            raise
        finally:
            connection.close()

    def _tag(self, domain, values):
        raw = json.dumps(values, sort_keys=True, separators=(",", ":"), allow_nan=False).encode()
        return hmac.new(self._key, b"larenor:sound-source:" + domain + b":v1\0" + raw, hashlib.sha256).hexdigest()

    def _migrate(self):
        with self._connection(write=True) as connection:
            connection.executescript("""
            CREATE TABLE IF NOT EXISTS source_metadata (
              singleton INTEGER PRIMARY KEY CHECK(singleton=1), version INTEGER NOT NULL CHECK(version=1));
            CREATE TABLE IF NOT EXISTS source_configurations (
              owner_id TEXT PRIMARY KEY, revision INTEGER NOT NULL,
              payload_json TEXT NOT NULL, authentication_tag TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS source_statuses (
              owner_id TEXT PRIMARY KEY, config_revision INTEGER NOT NULL,
              payload_json TEXT NOT NULL, authentication_tag TEXT NOT NULL);
            """)
            rows = connection.execute("SELECT * FROM source_metadata").fetchall()
            if not rows:
                connection.execute("INSERT INTO source_metadata VALUES(1,1)")
            elif len(rows) != 1 or rows[0]["version"] != 1:
                raise ValueError("invalid_schema")

    def _config(self, row):
        if row is None:
            return None
        if (type(row["revision"]) is not int or not 1 <= row["revision"] < 2**63
                or not secrets.compare_digest(row["authentication_tag"], self._tag(
                    b"config", [row["owner_id"], row["revision"], row["payload_json"]]))):
            raise ValueError("invalid_config")
        value = FrigateSoundSource.model_validate_json(row["payload_json"])
        if (value.ownerId != row["owner_id"] or value.revision != row["revision"]
                or value.model_dump_json() != row["payload_json"]):
            raise ValueError("invalid_config")
        return value

    def _status(self, row):
        if row is None:
            return None
        if not secrets.compare_digest(row["authentication_tag"], self._tag(
                b"status", [row["owner_id"], row["config_revision"], row["payload_json"]])):
            raise ValueError("invalid_status")
        return SoundSourceStatus.model_validate_json(row["payload_json"])

    def _actor(self, actor):
        with self._primary.connection() as connection:
            self._auth.assert_current(connection, actor)
            row = connection.execute(
                "SELECT revision,role,disabled,must_change_password FROM users WHERE id=?", (actor.id,)
            ).fetchone()
        if (row is None or row["disabled"] or row["must_change_password"] or row["role"] != actor.role):
            raise ApiError("forbidden", 403)
        return row["revision"]

    def validate_storage(self):
        try:
            with self._connection() as connection:
                configs = connection.execute("SELECT * FROM source_configurations LIMIT 129").fetchall()
                statuses = connection.execute("SELECT * FROM source_statuses LIMIT 129").fetchall()
                if len(configs) > 128 or len(statuses) > 128:
                    raise ValueError("too_many_sources")
                decoded = {row["owner_id"]: self._config(row) for row in configs}
                for row in statuses:
                    if row["owner_id"] not in decoded or row["config_revision"] != decoded[row["owner_id"]].revision:
                        raise ValueError("orphan_status")
                    self._status(row)
        except (sqlite3.Error, TypeError, ValueError):
            raise StartupError("sound_source_storage_invalid") from None

    def get(self, actor):
        self._actor(actor)
        try:
            with self._connection() as connection:
                return self._config(connection.execute(
                    "SELECT * FROM source_configurations WHERE owner_id=?", (actor.id,)
                ).fetchone())
        except (sqlite3.Error, TypeError, ValueError):
            raise ApiError("camera_search_source_unavailable", 503) from None

    def put(self, actor, value, expected_revision):
        self._actor(actor)
        try:
            with self._connection(write=True) as connection:
                old = self._config(connection.execute(
                    "SELECT * FROM source_configurations WHERE owner_id=?", (actor.id,)
                ).fetchone())
                if (old is None) != (expected_revision is None) or (old is not None and old.revision != expected_revision):
                    raise ApiError("revision_conflict", 409)
                if value.ownerId != actor.id or value.revision != (1 if old is None else old.revision + 1):
                    raise ApiError("revision_conflict", 409)
                payload = value.model_dump_json()
                tag = self._tag(b"config", [actor.id, value.revision, payload])
                connection.execute(
                    "INSERT INTO source_configurations VALUES(?,?,?,?) ON CONFLICT(owner_id) DO UPDATE SET "
                    "revision=excluded.revision,payload_json=excluded.payload_json,authentication_tag=excluded.authentication_tag",
                    (actor.id, value.revision, payload, tag),
                )
                connection.execute("DELETE FROM source_statuses WHERE owner_id=?", (actor.id,))
                return value
        except ApiError:
            raise
        except (sqlite3.Error, TypeError, ValueError):
            raise ApiError("camera_search_source_unavailable", 503) from None

    def assert_current(self, actor, expected):
        current = self.get(actor)
        if current != expected:
            raise ApiError("revision_conflict", 409)

    def save_status(self, actor, source, status):
        self._actor(actor)
        status = SoundSourceStatus.model_validate(status)
        try:
            with self._connection(write=True) as connection:
                current = self._config(connection.execute(
                    "SELECT * FROM source_configurations WHERE owner_id=?", (actor.id,)
                ).fetchone())
                if current != source:
                    raise ApiError("revision_conflict", 409)
                payload = status.model_dump_json()
                tag = self._tag(b"status", [actor.id, source.revision, payload])
                connection.execute(
                    "INSERT INTO source_statuses VALUES(?,?,?,?) ON CONFLICT(owner_id) DO UPDATE SET "
                    "config_revision=excluded.config_revision,payload_json=excluded.payload_json,authentication_tag=excluded.authentication_tag",
                    (actor.id, source.revision, payload, tag),
                )
        except ApiError:
            raise
        except (sqlite3.Error, TypeError, ValueError):
            raise ApiError("camera_search_source_unavailable", 503) from None

    def status(self, actor):
        source = self.get(actor)
        if source is None or not source.consentGranted:
            return None
        try:
            with self._connection() as connection:
                row = connection.execute("SELECT * FROM source_statuses WHERE owner_id=?", (actor.id,)).fetchone()
                if row is None or row["config_revision"] != source.revision:
                    return None
                return self._status(row)
        except (sqlite3.Error, TypeError, ValueError):
            raise ApiError("camera_search_source_unavailable", 503) from None
