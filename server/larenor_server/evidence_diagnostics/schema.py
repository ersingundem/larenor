"""Strict storage migration for evidence diagnostics."""

import sqlite3

from ..errors import StartupError


TABLES = {
    "evidence_diagnostics": """CREATE TABLE evidence_diagnostics (
        id TEXT PRIMARY KEY,
        owner_id TEXT NOT NULL,
        family_id TEXT NOT NULL,
        request_key TEXT NOT NULL,
        revision INTEGER NOT NULL CHECK(revision > 0),
        request_fingerprint TEXT NOT NULL,
        created_at_ms INTEGER NOT NULL CHECK(created_at_ms >= 0),
        result_json TEXT NOT NULL,
        record_tag TEXT NOT NULL,
        UNIQUE(owner_id,family_id,request_key))""",
    "evidence_diagnostic_repair_previews": """CREATE TABLE evidence_diagnostic_repair_previews (
        id TEXT PRIMARY KEY,
        diagnosis_id TEXT NOT NULL REFERENCES evidence_diagnostics(id) ON DELETE CASCADE,
        owner_id TEXT NOT NULL,
        family_id TEXT NOT NULL,
        request_key TEXT NOT NULL,
        diagnosis_revision INTEGER NOT NULL CHECK(diagnosis_revision > 0),
        request_fingerprint TEXT NOT NULL,
        created_at_ms INTEGER NOT NULL CHECK(created_at_ms >= 0),
        expires_at_ms INTEGER NOT NULL CHECK(expires_at_ms > created_at_ms),
        preview_json TEXT NOT NULL,
        record_tag TEXT NOT NULL,
        UNIQUE(owner_id,family_id,request_key))""",
}

INDEXES = {
    "evidence_diagnostics_created":
        "CREATE INDEX evidence_diagnostics_created ON evidence_diagnostics(created_at_ms,id)",
    "evidence_diagnostic_previews_created":
        "CREATE INDEX evidence_diagnostic_previews_created "
        "ON evidence_diagnostic_repair_previews(created_at_ms,id)",
}


def migrate_evidence_diagnostics(connection: sqlite3.Connection) -> None:
    try:
        marker = connection.execute(
            "SELECT value FROM metadata WHERE key='evidence_diagnostic_schema'"
        ).fetchone()
        rows = connection.execute(
            "SELECT name,type,sql FROM sqlite_master WHERE "
            "name GLOB 'evidence_diagnostic*' OR tbl_name GLOB 'evidence_diagnostic*'"
        ).fetchall()
        actual = {row["name"]: row for row in rows if row["sql"] is not None}
        if marker is None:
            if actual:
                raise ValueError("unmarked_evidence_diagnostic_storage")
            for statement in TABLES.values():
                connection.execute(statement)
            for statement in INDEXES.values():
                connection.execute(statement)
            connection.execute(
                "INSERT INTO metadata VALUES('evidence_diagnostic_schema','1')"
            )
            return
        expected = TABLES | INDEXES
        if (
            marker["value"] != "1"
            or set(actual) != set(expected)
            or any(
                row["type"] != ("table" if name in TABLES else "index")
                or " ".join(row["sql"].split()) != " ".join(expected[name].split())
                for name, row in actual.items()
            )
        ):
            raise ValueError("invalid_evidence_diagnostic_storage")
    except (sqlite3.Error, TypeError, ValueError):
        raise StartupError("evidence_diagnostic_storage_invalid") from None
