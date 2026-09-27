import sqlite3

from ..errors import StartupError


CREATE = """CREATE TABLE automation_drafts (
    id TEXT PRIMARY KEY, owner_id TEXT NOT NULL, family_id TEXT NOT NULL,
    request_key TEXT NOT NULL, transcript_hash TEXT NOT NULL, resource_id TEXT NOT NULL,
    action TEXT NOT NULL CHECK(action IN ('turn_on','turn_off')),
    resource_revision INTEGER NOT NULL, acl_revision INTEGER NOT NULL,
    binding_revision INTEGER NOT NULL, service_revision INTEGER NOT NULL,
    revision INTEGER NOT NULL, state TEXT NOT NULL CHECK(state IN ('draft','activated')),
    rule_id TEXT, created_at REAL NOT NULL, expires_at REAL NOT NULL,
    record_tag TEXT NOT NULL, UNIQUE(owner_id,family_id,request_key))"""


def migrate_automation_drafts(connection: sqlite3.Connection) -> None:
    try:
        marker = connection.execute(
            "SELECT value FROM metadata WHERE key='automation_draft_schema'"
        ).fetchone()
        row = connection.execute(
            "SELECT type,sql FROM sqlite_master WHERE name='automation_drafts'"
        ).fetchone()
        if marker is None:
            if row is not None:
                raise ValueError("unmarked_automation_drafts")
            connection.execute(CREATE)
            connection.execute("INSERT INTO metadata VALUES('automation_draft_schema','1')")
        elif (
            marker["value"] != "1"
            or row is None
            or row["type"] != "table"
            or " ".join(row["sql"].split()) != " ".join(CREATE.split())
        ):
            raise ValueError("invalid_automation_draft_schema")
    except (sqlite3.Error, TypeError, ValueError):
        raise StartupError("automation_draft_storage_invalid") from None
