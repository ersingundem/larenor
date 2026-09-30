"""Separate append-only backup target. This is not the restic REST protocol."""

import asyncio
from contextlib import contextmanager
import hashlib
import hmac
import json
import os
from pathlib import Path
import sqlite3
import threading
import time

from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse, Response
from pydantic import Field, SecretStr, field_validator, model_validator

from ..errors import ApiError, StartupError
from ..files import checked_path, private_create, private_directory, private_read
from ..models import StrictModel
from .immutable_models import AppendOnlyRemoteReceipt, TargetId

MAX_OBJECT_BYTES = 64 * 1024 * 1024
MAX_OBJECTS = 10_000
DAY = 86_400


class AppendTargetPolicy(StrictModel):
    contractVersion: int = Field(ge=1, le=1)
    targetId: TargetId
    dataDirectory: str
    sealKeyFile: str
    writeToken: SecretStr = Field(repr=False)
    recoveryToken: SecretStr = Field(repr=False)
    quotaBytes: int = Field(ge=MAX_OBJECT_BYTES, le=10 * 1024**4)
    minimumRetentionDays: int = Field(ge=7, le=3650)

    @field_validator("dataDirectory", "sealKeyFile")
    @classmethod
    def absolute_path(cls, value):
        checked_path(Path(value))
        return value

    @model_validator(mode="after")
    def separated_authority(self):
        writer, recovery = self.writeToken.get_secret_value(), self.recoveryToken.get_secret_value()
        if (not 32 <= len(writer) <= 512 or not 32 <= len(recovery) <= 512
                or hmac.compare_digest(writer, recovery)
                or any(ord(c) < 33 or ord(c) > 126 for c in writer + recovery)
                or Path(self.sealKeyFile).is_relative_to(Path(self.dataDirectory))):
            raise ValueError("invalid_target_policy")
        return self

    @classmethod
    def load(cls, path):
        def pairs(values):
            result = {}
            for key, value in values:
                if key in result:
                    raise ValueError("duplicate_key")
                result[key] = value
            return result
        try:
            return cls.model_validate(json.loads(private_read(Path(path), 16_384), object_pairs_hook=pairs))
        except Exception:
            raise StartupError("append_target_configuration_invalid") from None


class AppendTargetStore:
    def __init__(self, policy, *, clock=time.time):
        self.policy, self.clock = policy, clock
        self._lock = threading.Lock()
        self._key = private_read(Path(policy.sealKeyFile), 32)
        if len(self._key) != 32:
            raise StartupError("append_target_configuration_invalid")
        directory = Path(policy.dataDirectory)
        private_directory(directory)
        self.path = directory / "append-target.sqlite3"
        created = False
        try:
            private_create(self.path, b"")
            created = True
        except FileExistsError:
            self._check_file()
        with self._connection() as connection:
            if created:
                connection.executescript("""BEGIN IMMEDIATE;
                CREATE TABLE objects(
                    object_id TEXT PRIMARY KEY, requested_until INTEGER NOT NULL,
                    payload BLOB NOT NULL, receipt TEXT NOT NULL, seal TEXT NOT NULL);
                CREATE TABLE ledger(
                    singleton INTEGER PRIMARY KEY CHECK(singleton=1),
                    object_count INTEGER NOT NULL, used_bytes INTEGER NOT NULL, seal TEXT NOT NULL);
                """)
                connection.execute("INSERT INTO ledger VALUES(1,0,0,?)", (self._seal(["ledger", policy.targetId, 0, 0]),))
                connection.commit()
            tables = connection.execute("SELECT name,type FROM sqlite_master WHERE name NOT LIKE 'sqlite_%'").fetchall()
            if set(map(tuple, tables)) != {("objects", "table"), ("ledger", "table")}:
                raise StartupError("append_target_storage_invalid")
            self._validate(connection, full=True)

    def _check_file(self):
        # Validate ownership without reading a potentially large SQLite database.
        import stat
        checked_path(self.path)
        info = self.path.stat()
        if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid()
                or stat.S_IMODE(info.st_mode) != 0o600 or info.st_nlink != 1):
            raise StartupError("append_target_storage_invalid")

    @contextmanager
    def _connection(self):
        self._check_file()
        connection = sqlite3.connect(self.path, timeout=1, isolation_level=None)
        connection.row_factory = sqlite3.Row
        try:
            connection.execute("PRAGMA synchronous=FULL")
            yield connection
        finally:
            connection.close()

    def _seal(self, value):
        raw = json.dumps(value, sort_keys=True, separators=(",", ":")).encode()
        return hmac.new(self._key, b"larenor-append-target-v1\0" + raw, hashlib.sha256).hexdigest()

    def _row_seal(self, object_id, requested_until, receipt):
        return self._seal(["object", self.policy.targetId, object_id, requested_until, receipt])

    def _receipt(self, row):
        if not hmac.compare_digest(row["seal"], self._row_seal(row["object_id"], row["requested_until"], row["receipt"])):
            raise ApiError("append_target_storage_invalid", 503)
        receipt = AppendOnlyRemoteReceipt.model_validate_json(row["receipt"])
        if receipt.targetId != self.policy.targetId or receipt.objectId != row["object_id"]:
            raise ApiError("append_target_storage_invalid", 503)
        return receipt

    def _row(self, connection, object_id):
        row = connection.execute("SELECT object_id,requested_until,receipt,seal,length(payload) AS bytes FROM objects WHERE object_id=?", (object_id,)).fetchone()
        if row is not None and not 1 <= row["bytes"] <= MAX_OBJECT_BYTES:
            raise ApiError("append_target_storage_invalid", 503)
        return row

    def _validate(self, connection, *, full=False):
        state = connection.execute("SELECT * FROM ledger LIMIT 2").fetchall()
        totals = connection.execute("SELECT COUNT(*),COALESCE(SUM(length(payload)),0) FROM objects").fetchone()
        if (len(state) != 1 or state[0]["singleton"] != 1
                or totals[0] != state[0]["object_count"] or totals[1] != state[0]["used_bytes"]
                or not 0 <= totals[0] <= MAX_OBJECTS or not 0 <= totals[1] <= self.policy.quotaBytes
                or not hmac.compare_digest(state[0]["seal"], self._seal(["ledger", self.policy.targetId, *totals]))):
            raise ApiError("append_target_storage_invalid", 503)
        if full:
            for row in connection.execute("SELECT object_id,requested_until,receipt,seal,length(payload) AS bytes FROM objects"):
                receipt = self._receipt(row)
                if not 1 <= row["bytes"] <= MAX_OBJECT_BYTES or row["bytes"] != receipt.byteLength:
                    raise ApiError("append_target_storage_invalid", 503)
                payload = connection.execute("SELECT payload FROM objects WHERE object_id=?", (row["object_id"],)).fetchone()[0]
                if hashlib.sha256(payload).hexdigest() != receipt.sha256:
                    raise ApiError("append_target_storage_invalid", 503)
        return tuple(totals)

    def append(self, object_id, payload, digest, requested_until):
        if (len(object_id) != 32 or any(c not in "0123456789abcdef" for c in object_id)
                or len(digest) != 64 or any(c not in "0123456789abcdef" for c in digest)
                or not 1 <= len(payload) <= MAX_OBJECT_BYTES
                or not hmac.compare_digest(hashlib.sha256(payload).hexdigest(), digest)):
            raise ApiError("invalid_append", 400)
        with self._lock, self._connection() as connection:
            connection.execute("BEGIN IMMEDIATE")
            try:
                count, used = self._validate(connection)
                old = self._row(connection, object_id)
                if old is not None:
                    receipt = self._receipt(old)
                    if (receipt.sha256 != digest or receipt.byteLength != len(payload)
                            or old["requested_until"] != requested_until):
                        raise ApiError("append_conflict", 409)
                    stored = connection.execute("SELECT payload FROM objects WHERE object_id=?", (object_id,)).fetchone()[0]
                    if stored != payload:
                        raise ApiError("append_target_storage_invalid", 503)
                    return receipt
                now = int(self.clock())
                if type(requested_until) is not int or not now < requested_until <= now + 3650 * DAY:
                    raise ApiError("invalid_retention", 400)
                if count >= MAX_OBJECTS or used + len(payload) > self.policy.quotaBytes:
                    raise ApiError("append_quota_exceeded", 413)
                receipt = AppendOnlyRemoteReceipt(contractVersion=1, targetId=self.policy.targetId,
                    objectId=object_id, remoteReceiptId=object_id, storedAt=now,
                    protectedUntil=max(requested_until, now + self.policy.minimumRetentionDays * DAY),
                    byteLength=len(payload), sha256=digest, quotaUsedBytes=used + len(payload),
                    quotaBytes=self.policy.quotaBytes, writerScope="append_only")
                encoded = receipt.model_dump_json()
                connection.execute("INSERT INTO objects VALUES(?,?,?,?,?)", (object_id, requested_until,
                    payload, encoded, self._row_seal(object_id, requested_until, encoded)))
                connection.execute("UPDATE ledger SET object_count=?,used_bytes=?,seal=? WHERE singleton=1",
                    (count + 1, used + len(payload), self._seal(["ledger", self.policy.targetId, count + 1, used + len(payload)])))
                connection.commit()
                return receipt
            finally:
                connection.rollback()

    def read(self, object_id):
        with self._lock, self._connection() as connection:
            connection.execute("BEGIN")
            self._validate(connection)
            row = self._row(connection, object_id)
            if row is None:
                raise ApiError("not_found", 404)
            receipt = self._receipt(row)
            payload = connection.execute("SELECT payload FROM objects WHERE object_id=?", (object_id,)).fetchone()[0]
            if len(payload) != receipt.byteLength or hashlib.sha256(payload).hexdigest() != receipt.sha256:
                raise ApiError("append_target_storage_invalid", 503)
            return receipt, payload

    def points(self):
        with self._lock, self._connection() as connection:
            connection.execute("BEGIN")
            _count, used = self._validate(connection)
            rows = connection.execute("SELECT object_id,requested_until,receipt,seal FROM objects ORDER BY rowid DESC LIMIT 100").fetchall()
            return {"points": [self._receipt(row).model_dump() for row in rows],
                    "quotaUsedBytes": used, "quotaBytes": self.policy.quotaBytes}


def create_append_target(policy, *, clock=time.time):
    store = AppendTargetStore(policy, clock=clock)
    app = FastAPI(docs_url=None, redoc_url=None, openapi_url=None)
    app.state.append_store = store
    admission = asyncio.Lock()

    @app.exception_handler(ApiError)
    async def failed(_request, error):
        return JSONResponse({"error": {"code": error.code}}, status_code=error.status,
                            headers={"Cache-Control": "no-store"})

    @app.exception_handler(Exception)
    async def unavailable(_request, _error):
        return JSONResponse({"error": {"code": "append_target_unavailable"}}, status_code=503)

    def authorize(request, target_id, recovery=False):
        token = policy.recoveryToken if recovery else policy.writeToken
        if not hmac.compare_digest(request.headers.get("Authorization", ""), "Bearer " + token.get_secret_value()):
            raise ApiError("unauthorized", 401)
        if target_id != policy.targetId:
            raise ApiError("not_found", 404)

    @app.post("/v1/append/{target_id}/objects/{object_id}")
    async def append(target_id: str, object_id: str, request: Request):
        authorize(request, target_id)
        try:
            length = int(request.headers.get("Content-Length", ""))
            until = int(request.headers.get("X-Larenor-Protected-Until", ""))
        except ValueError:
            raise ApiError("invalid_append", 400) from None
        if (not 1 <= length <= MAX_OBJECT_BYTES or request.headers.get("Content-Type")
                != "application/vnd.larenor.core-backup"):
            raise ApiError("invalid_append", 413 if length > MAX_OBJECT_BYTES else 400)
        if admission.locked():
            raise ApiError("append_busy", 429)
        async with admission:
            payload = bytearray()
            try:
                async with asyncio.timeout(30):
                    async for chunk in request.stream():
                        if len(payload) + len(chunk) > length:
                            raise ApiError("invalid_append", 400)
                        payload.extend(chunk)
                if len(payload) != length:
                    raise ApiError("invalid_append", 400)
                receipt = await asyncio.to_thread(store.append, object_id, bytes(payload),
                    request.headers.get("X-Larenor-SHA256", ""), until)
                return JSONResponse(receipt.model_dump(), status_code=201, headers={"Cache-Control": "no-store"})
            except TimeoutError:
                raise ApiError("append_timeout", 408) from None
            finally:
                payload.clear()

    @app.get("/v1/recovery/{target_id}/objects/{object_id}")
    async def read(target_id: str, object_id: str, request: Request):
        authorize(request, target_id, recovery=True)
        receipt, payload = await asyncio.to_thread(store.read, object_id)
        return Response(payload, media_type="application/vnd.larenor.core-backup",
                        headers={"Cache-Control": "no-store", "X-Larenor-SHA256": receipt.sha256})

    @app.get("/v1/recovery/{target_id}/objects")
    async def points(target_id: str, request: Request):
        authorize(request, target_id, recovery=True)
        return JSONResponse(await asyncio.to_thread(store.points), headers={"Cache-Control": "no-store"})

    return app


def main(argv=None):
    import argparse
    import sys
    import uvicorn

    class Parser(argparse.ArgumentParser):
        def error(self, _message):
            raise ValueError("invalid_arguments")

    parser = Parser(description=__doc__)
    parser.add_argument("--policy", required=True, type=Path)
    parser.add_argument("--certfile", required=True, type=Path)
    parser.add_argument("--keyfile", required=True, type=Path)
    parser.add_argument("--host", default="0.0.0.0")
    parser.add_argument("--port", type=int, default=8099)
    parser.add_argument("--check-config", action="store_true")
    try:
        args = parser.parse_args(argv)
        if (args.host not in {"0.0.0.0", "127.0.0.1", "::"}
                or not 1024 <= args.port <= 65535):
            raise ValueError()
        policy = AppendTargetPolicy.load(args.policy)
        # Both TLS files must be owned private regular files. Never permit an
        # HTTP-only target or a credential-bearing reverse-proxy assumption.
        private_read(args.certfile, 65_536)
        private_read(args.keyfile, 65_536)
        import ssl
        tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        tls.minimum_version = ssl.TLSVersion.TLSv1_2
        tls.load_cert_chain(args.certfile, args.keyfile)
        if args.check_config:
            if len(private_read(Path(policy.sealKeyFile), 32)) != 32:
                raise ValueError()
            return 0
        app = create_append_target(policy)
        uvicorn.run(app, host=args.host, port=args.port, ssl_certfile=str(args.certfile),
                    ssl_keyfile=str(args.keyfile), log_level="critical", access_log=False,
                    limit_concurrency=4, timeout_keep_alive=5, server_header=False)
        return 0
    except Exception:
        print("append_target_unavailable", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
