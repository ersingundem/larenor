import hashlib
import hmac
import json
import sqlite3

from ..errors import ApiError, StartupError
from ..home_resources.models import HomeScope
from .models import EvidenceRecord, PutEvidence

_TABLE = """CREATE TABLE capability_evidence (
    id TEXT PRIMARY KEY, revision INTEGER NOT NULL CHECK(revision > 0),
    family_id TEXT NOT NULL, actor_id TEXT NOT NULL,
    request_key TEXT NOT NULL UNIQUE, request_hash TEXT NOT NULL,
    record_json TEXT NOT NULL, updated_at REAL NOT NULL,
    tag TEXT NOT NULL)"""


def migrate(connection):
    try:
        marker = connection.execute(
            "SELECT value FROM metadata WHERE key='capability_evidence_schema'"
        ).fetchone()
        actual = {
            row["name"]: row
            for row in connection.execute(
                "SELECT name,type,tbl_name,sql FROM sqlite_master "
                "WHERE name='capability_evidence' OR tbl_name='capability_evidence'"
            )
        }
        if marker is not None:
            expected_indexes = {
                "sqlite_autoindex_capability_evidence_1": "id",
                "sqlite_autoindex_capability_evidence_2": "request_key",
            }
            for name, column in expected_indexes.items():
                index = actual.pop(name, None)
                details = connection.execute(f"PRAGMA index_info('{name}')").fetchall()
                if (
                    index is None
                    or index["type"] != "index"
                    or index["tbl_name"] != "capability_evidence"
                    or index["sql"] is not None
                    or [(item["seqno"], item["name"]) for item in details]
                    != [(0, column)]
                ):
                    raise ValueError("invalid_evidence_index")
            indexes = connection.execute(
                "PRAGMA index_list('capability_evidence')"
            ).fetchall()
            if {
                (item["name"], item["unique"], item["origin"], item["partial"])
                for item in indexes
            } != {
                ("sqlite_autoindex_capability_evidence_1", 1, "pk", 0),
                ("sqlite_autoindex_capability_evidence_2", 1, "u", 0),
            }:
                raise ValueError("invalid_evidence_indexes")
        if marker is None:
            if actual:
                raise ValueError("unmarked_evidence")
            connection.execute(_TABLE)
            connection.execute(
                "INSERT INTO metadata VALUES('capability_evidence_schema','1')"
            )
        elif marker["value"] != "1" or set(actual) != {"capability_evidence"}:
            raise ValueError("invalid_evidence")
        elif actual["capability_evidence"]["type"] != "table" or " ".join(
            actual["capability_evidence"]["sql"].split()
        ) != " ".join(_TABLE.split()):
            raise ValueError("invalid_evidence_table")
    except (sqlite3.Error, ValueError, TypeError):
        raise StartupError("capability_evidence_storage_invalid") from None


class CapabilityEvidenceService:
    def __init__(self, db, auth, settings, key, context):
        self.db, self.auth, self.settings, self._key = db, auth, settings, key
        self.scope = HomeScope.model_validate(context.model_dump())

    def _authorize(self, actor, core_id, home_id):
        if (core_id, home_id) != (self.scope.coreId, self.scope.homeId):
            raise ApiError("not_found", 404)
        if actor.role != "admin" or actor.must_change_password:
            raise ApiError("forbidden", 403)
        self.auth.rate_limit([("capability_evidence", actor.id, 120)])

    def _tag(self, row):
        payload = json.dumps(
            [
                self.scope.coreId,
                self.scope.homeId,
                row["id"],
                row["revision"],
                row["family_id"],
                row["actor_id"],
                row["request_key"],
                row["request_hash"],
                row["record_json"],
                row["updated_at"],
            ],
            separators=(",", ":"),
            ensure_ascii=True,
        ).encode("ascii")
        return hmac.new(
            self._key, b"larenor-capability-evidence-v1\0" + payload, hashlib.sha256
        ).hexdigest()

    def _verify(self, row):
        if not hmac.compare_digest(row["tag"], self._tag(row)):
            raise ApiError("capability_evidence_storage_unavailable", 503)
        try:
            record = EvidenceRecord.model_validate_json(row["record_json"])
            if (
                record.id != row["id"]
                or record.revision != row["revision"]
                or record.updatedAt != row["updated_at"]
            ):
                raise ValueError("evidence_drift")
            return record
        except (ValueError, TypeError):
            raise ApiError("capability_evidence_storage_unavailable", 503) from None

    def validate_storage(self):
        try:
            with self.db.connection() as connection:
                rows = connection.execute(
                    "SELECT * FROM capability_evidence ORDER BY id LIMIT 257"
                ).fetchall()
                if len(rows) > 256:
                    raise ValueError("evidence_limit")
                for row in rows:
                    self._verify(row)
        except (ApiError, ValueError, sqlite3.Error):
            raise StartupError("capability_evidence_storage_invalid") from None

    def put(self, actor, core_id, home_id, evidence_id, body: PutEvidence):
        self._authorize(actor, core_id, home_id)
        if evidence_id != body.evidenceId:
            raise ApiError("invalid_request", 400)
        payload = body.model_dump_json(exclude={"requestKey", "expectedRevision"})
        request_hash = hashlib.sha256(
            json.dumps([body.expectedRevision, payload], separators=(",", ":")).encode(
                "utf-8"
            )
        ).hexdigest()
        try:
            with self.db.transaction() as connection:
                row = connection.execute(
                    "SELECT * FROM capability_evidence WHERE id=?", (evidence_id,)
                ).fetchone()
                duplicate = connection.execute(
                    "SELECT * FROM capability_evidence WHERE request_key=?",
                    (body.requestKey,),
                ).fetchone()
                if duplicate is not None:
                    record = self._verify(duplicate)
                    if (
                        duplicate["id"] != evidence_id
                        or duplicate["request_hash"] != request_hash
                        or duplicate["family_id"] != actor.family_id
                    ):
                        raise ApiError("capability_evidence_replay", 409)
                    return {
                        "record": record
                    }, 201 if body.expectedRevision == 0 else 200
                if row is None:
                    if body.expectedRevision != 0:
                        raise ApiError("capability_evidence_changed", 409)
                    count = connection.execute(
                        "SELECT COUNT(*) FROM capability_evidence"
                    ).fetchone()[0]
                    if count >= 256:
                        raise ApiError("capability_evidence_limit_reached", 409)
                    revision = 1
                else:
                    self._verify(row)
                    if row["family_id"] != actor.family_id:
                        raise ApiError("not_found", 404)
                    if row["revision"] != body.expectedRevision:
                        raise ApiError("capability_evidence_changed", 409)
                    revision = row["revision"] + 1
                record = EvidenceRecord(
                    schemaVersion=1,
                    id=evidence_id,
                    revision=revision,
                    capabilityId=body.capabilityId,
                    target=body.target,
                    outcome=body.outcome,
                    artifactName=body.artifactName,
                    artifactSha256=body.artifactSha256,
                    sourceCommit=body.sourceCommit,
                    testCase=body.testCase,
                    updatedAt=float(self.settings.clock()),
                )
                new = {
                    "id": evidence_id,
                    "revision": revision,
                    "family_id": actor.family_id,
                    "actor_id": actor.id,
                    "request_key": body.requestKey,
                    "request_hash": request_hash,
                    "record_json": record.model_dump_json(),
                    "updated_at": record.updatedAt,
                }
                new["tag"] = self._tag(new)
                connection.execute(
                    "INSERT INTO capability_evidence VALUES(?,?,?,?,?,?,?,?,?) "
                    "ON CONFLICT(id) DO UPDATE SET revision=excluded.revision, "
                    "family_id=excluded.family_id,actor_id=excluded.actor_id,"
                    "request_key=excluded.request_key,request_hash=excluded.request_hash,"
                    "record_json=excluded.record_json,updated_at=excluded.updated_at,tag=excluded.tag",
                    tuple(new.values()),
                )
                return {"record": record}, 201 if revision == 1 else 200
        except sqlite3.Error:
            raise ApiError("capability_evidence_storage_unavailable", 503) from None

    def list(self, actor, core_id, home_id, after, limit):
        self._authorize(actor, core_id, home_id)
        try:
            with self.db.connection() as connection:
                # Verify the entire bounded registry before publishing a page.
                rows = connection.execute(
                    "SELECT * FROM capability_evidence ORDER BY id LIMIT 257"
                ).fetchall()
                if len(rows) > 256:
                    raise ApiError("capability_evidence_storage_unavailable", 503)
                records = [self._verify(row) for row in rows]
                if any(row["family_id"] != actor.family_id for row in rows):
                    raise ApiError("capability_evidence_storage_unavailable", 503)
                page = [
                    record for record in records if after is None or record.id > after
                ]
                return {
                    "schemaVersion": 1,
                    "scope": self.scope,
                    "records": page[:limit],
                    "nextAfter": page[limit - 1].id if len(page) > limit else None,
                }
        except sqlite3.Error:
            raise ApiError("capability_evidence_storage_unavailable", 503) from None
