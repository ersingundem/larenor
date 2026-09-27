import sqlite3

from ..errors import StartupError


TABLES = {
    "ai_resource_policy": """CREATE TABLE ai_resource_policy (
        id INTEGER PRIMARY KEY CHECK(id=1),
        revision INTEGER NOT NULL CHECK(revision > 0),
        max_memory_mb INTEGER NOT NULL CHECK(max_memory_mb >= 64),
        max_cpu_percent INTEGER NOT NULL CHECK(max_cpu_percent BETWEEN 1 AND 100),
        max_concurrent_jobs INTEGER NOT NULL CHECK(max_concurrent_jobs BETWEEN 1 AND 16),
        media_cpu_percent INTEGER NOT NULL CHECK(media_cpu_percent BETWEEN 1 AND 100),
        updated_at REAL NOT NULL,
        record_tag TEXT NOT NULL)""",
    "ai_resource_jobs": """CREATE TABLE ai_resource_jobs (
        id TEXT PRIMARY KEY,
        owner_id TEXT NOT NULL,
        family_id TEXT NOT NULL,
        request_key TEXT NOT NULL,
        revision INTEGER NOT NULL CHECK(revision > 0),
        kind TEXT NOT NULL CHECK(kind IN ('assistant','vision','embedding','automation')),
        label TEXT NOT NULL,
        priority INTEGER NOT NULL CHECK(priority BETWEEN 0 AND 100),
        memory_mb INTEGER NOT NULL CHECK(memory_mb >= 64),
        cpu_percent INTEGER NOT NULL CHECK(cpu_percent BETWEEN 1 AND 100),
        state TEXT NOT NULL CHECK(state IN ('queued','cancelled','completed')),
        created_at REAL NOT NULL,
        updated_at REAL NOT NULL,
        record_tag TEXT NOT NULL,
        UNIQUE(owner_id,family_id,request_key))""",
    "ai_resource_media_leases": """CREATE TABLE ai_resource_media_leases (
        family_id TEXT PRIMARY KEY,
        owner_id TEXT NOT NULL,
        expires_at REAL NOT NULL,
        updated_at REAL NOT NULL,
        record_tag TEXT NOT NULL)""",
}

INDEXES = {
    "ai_resource_jobs_order": "CREATE INDEX ai_resource_jobs_order ON ai_resource_jobs(state,priority DESC,created_at,id)",
    "ai_resource_media_expiry": "CREATE INDEX ai_resource_media_expiry ON ai_resource_media_leases(expires_at)",
}


def migrate_ai_resources(connection: sqlite3.Connection) -> None:
    try:
        marker = connection.execute(
            "SELECT value FROM metadata WHERE key='ai_resource_schema'"
        ).fetchone()
        rows = connection.execute(
            "SELECT name,type,sql FROM sqlite_master WHERE "
            "name GLOB 'ai_resource_*' OR tbl_name GLOB 'ai_resource_*'"
        ).fetchall()
        actual = {row["name"]: row for row in rows if row["sql"] is not None}
        if marker is None:
            if actual:
                raise ValueError("unmarked_ai_resource_storage")
            for statement in TABLES.values():
                connection.execute(statement)
            for statement in INDEXES.values():
                connection.execute(statement)
            connection.execute("INSERT INTO metadata VALUES('ai_resource_schema','1')")
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
            raise ValueError("invalid_ai_resource_storage")
    except (sqlite3.Error, TypeError, ValueError):
        raise StartupError("ai_resource_storage_invalid") from None

