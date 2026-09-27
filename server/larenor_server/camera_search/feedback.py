"""Durable, privacy-preserving correction journal for F41 search results."""

import hashlib
import hmac
import json
import sqlite3
import unicodedata
import uuid

from ..errors import ApiError, StartupError
from .models import CameraEvidenceLink, CameraSearchFeedbackResponse


TABLE = """CREATE TABLE camera_search_feedback (
 id TEXT PRIMARY KEY CHECK(length(id)=32), account_id TEXT NOT NULL CHECK(length(account_id)=32),
 session_family_id TEXT NOT NULL CHECK(length(session_family_id)=32),
 request_id TEXT NOT NULL CHECK(length(request_id)=32), request_hash TEXT NOT NULL CHECK(length(request_hash)=64),
 query_hash TEXT NOT NULL CHECK(length(query_hash)=64), evidence_hash TEXT NOT NULL CHECK(length(evidence_hash)=64),
 reason TEXT NOT NULL CHECK(reason IN ('irrelevant','wrong_time','wrong_camera','wrong_summary')),
 index_revision INTEGER NOT NULL CHECK(index_revision>0), created_at INTEGER NOT NULL CHECK(created_at>0),
 envelope_tag TEXT NOT NULL CHECK(length(envelope_tag)=64),
 UNIQUE(account_id,session_family_id,request_id))"""
INDEX = """CREATE INDEX camera_search_feedback_lookup
 ON camera_search_feedback(account_id,query_hash,evidence_hash)"""
MAX_FEEDBACK = 10_000


def _normal(value):
    return " ".join(value.split()) if type(value) is str else None


def migrate_camera_search_feedback(connection):
    try:
        marker = connection.execute(
            "SELECT value FROM metadata WHERE key='camera_search_feedback_schema'"
        ).fetchone()
        expected = {
            "camera_search_feedback": TABLE,
            "camera_search_feedback_lookup": INDEX,
        }
        rows = connection.execute(
            "SELECT name,sql FROM sqlite_master WHERE name IN (?,?)",
            tuple(expected),
        ).fetchall()
        actual = {row["name"]: row["sql"] for row in rows}
        if marker is None:
            if actual:
                raise ValueError("unmarked_camera_search_feedback")
            connection.execute(TABLE)
            connection.execute(INDEX)
            connection.execute(
                "INSERT INTO metadata(key,value) VALUES('camera_search_feedback_schema','1')"
            )
            return
        if (marker["value"] != "1" or set(actual) != set(expected)
                or any(_normal(actual[name]) != _normal(sql)
                       for name, sql in expected.items())):
            raise ValueError("invalid_camera_search_feedback")
    except (ValueError, TypeError, sqlite3.Error):
        raise StartupError("camera_search_feedback_schema_unsupported") from None


class CameraSearchFeedbackService:
    def __init__(self, db, key, clock):
        if not isinstance(key, bytes) or len(key) < 32:
            raise ValueError("invalid_feedback_key")
        self.db, self.key, self.clock = db, key, clock

    @staticmethod
    def _canonical(value):
        return json.dumps(
            value, sort_keys=True, separators=(",", ":"), allow_nan=False,
        ).encode("utf-8")

    @staticmethod
    def _query_hash(query):
        normalized = " ".join(
            unicodedata.normalize("NFKC", query).casefold().split()
        )
        return hashlib.sha256(
            b"camera-search-feedback-query-v1\0" + normalized.encode("utf-8")
        ).hexdigest()

    @classmethod
    def _evidence_hash(cls, evidence):
        evidence = CameraEvidenceLink.model_validate(evidence)
        return hashlib.sha256(
            b"camera-search-feedback-evidence-v1\0"
            + cls._canonical(evidence.model_dump(mode="json"))
        ).hexdigest()

    def _tag(self, row):
        body = {key: row[key] for key in (
            "id", "account_id", "session_family_id", "request_id",
            "request_hash", "query_hash", "evidence_hash", "reason",
            "index_revision", "created_at",
        )}
        return hmac.new(
            self.key, b"camera-search-feedback-row-v1\0" + self._canonical(body),
            hashlib.sha256,
        ).hexdigest()

    def _valid(self, row):
        return hmac.compare_digest(row["envelope_tag"], self._tag(row))

    def validate_storage(self):
        try:
            with self.db.connection() as connection:
                rows = connection.execute(
                    "SELECT * FROM camera_search_feedback ORDER BY created_at,id LIMIT ?",
                    (MAX_FEEDBACK + 1,),
                ).fetchall()
            if len(rows) > MAX_FEEDBACK or any(not self._valid(row) for row in rows):
                raise ValueError("invalid_camera_search_feedback")
        except (ValueError, TypeError, sqlite3.Error):
            raise StartupError("camera_search_feedback_storage_invalid") from None

    def record(self, actor, body):
        query_hash = self._query_hash(body.query)
        evidence_hash = self._evidence_hash(body.evidence)
        request_payload = {
            "account": actor.id, "family": actor.family_id,
            "request": body.requestId, "query": query_hash,
            "evidence": evidence_hash, "reason": body.reason,
            "index": body.expectedIndexRevision,
        }
        request_hash = hashlib.sha256(
            b"camera-search-feedback-request-v1\0" + self._canonical(request_payload)
        ).hexdigest()
        with self.db.transaction() as connection:
            existing = connection.execute(
                "SELECT * FROM camera_search_feedback WHERE account_id=? AND session_family_id=? AND request_id=?",
                (actor.id, actor.family_id, body.requestId),
            ).fetchone()
            if existing is not None:
                if (not self._valid(existing)
                        or not hmac.compare_digest(existing["request_hash"], request_hash)):
                    raise ApiError("idempotency_conflict", 409)
                return CameraSearchFeedbackResponse(
                    schemaVersion=1, requestId=body.requestId, recorded=True)
            count = connection.execute(
                "SELECT COUNT(*) AS count FROM camera_search_feedback"
            ).fetchone()["count"]
            if count >= MAX_FEEDBACK:
                raise ApiError("revision_conflict", 409)
            row = {
                "id": uuid.uuid4().hex, "account_id": actor.id,
                "session_family_id": actor.family_id,
                "request_id": body.requestId, "request_hash": request_hash,
                "query_hash": query_hash, "evidence_hash": evidence_hash,
                "reason": body.reason, "index_revision": body.expectedIndexRevision,
                "created_at": int(self.clock()),
            }
            row["envelope_tag"] = self._tag(row)
            connection.execute(
                "INSERT INTO camera_search_feedback VALUES(?,?,?,?,?,?,?,?,?,?,?)",
                tuple(row[key] for key in (
                    "id", "account_id", "session_family_id", "request_id",
                    "request_hash", "query_hash", "evidence_hash", "reason",
                    "index_revision", "created_at", "envelope_tag",
                )),
            )
        return CameraSearchFeedbackResponse(
            schemaVersion=1, requestId=body.requestId, recorded=True)

    def filter_reported(self, actor, query, results):
        query_hash = self._query_hash(query)
        with self.db.connection() as connection:
            rows = connection.execute(
                "SELECT * FROM camera_search_feedback WHERE account_id=? AND query_hash=?",
                (actor.id, query_hash),
            ).fetchall()
        if any(not self._valid(row) for row in rows):
            raise ApiError("service_unavailable", 503)
        hidden = {row["evidence_hash"] for row in rows}
        return [item for item in results if self._evidence_hash(item.evidence) not in hidden]
