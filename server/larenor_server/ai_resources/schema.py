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
        state TEXT NOT NULL CHECK(state IN ('queued','dispatching','running',
            'cancel_requested','cancelled','completed','failed','uncertain')),
        created_at REAL NOT NULL,
        updated_at REAL NOT NULL,
        record_tag TEXT NOT NULL,
        UNIQUE(owner_id,family_id,request_key))""",
    "ai_resource_runs": """CREATE TABLE ai_resource_runs (
        job_id TEXT PRIMARY KEY,
        dispatch_id TEXT NOT NULL UNIQUE,
        provider TEXT NOT NULL,
        phase TEXT NOT NULL CHECK(phase IN ('reserved','starting','running',
            'cancel_requested','succeeded','failed','cancelled','uncertain')),
        started_at REAL,
        finished_at REAL,
        result_code TEXT,
        exit_code INTEGER CHECK(exit_code IS NULL OR exit_code BETWEEN 0 AND 255),
        memory_peak_mb INTEGER CHECK(memory_peak_mb IS NULL OR memory_peak_mb >= 0),
        cpu_millis INTEGER CHECK(cpu_millis IS NULL OR cpu_millis >= 0),
        output_sha256 TEXT,
        output_bytes INTEGER CHECK(output_bytes IS NULL OR output_bytes >= 0),
        released_at REAL,
        updated_at REAL NOT NULL,
        record_tag TEXT NOT NULL)""",
    "ai_resource_media_leases": """CREATE TABLE ai_resource_media_leases (
        family_id TEXT PRIMARY KEY,
        owner_id TEXT NOT NULL,
        expires_at REAL NOT NULL,
        updated_at REAL NOT NULL,
        record_tag TEXT NOT NULL)""",
    "ai_resource_measurements": """CREATE TABLE ai_resource_measurements (
        sequence INTEGER PRIMARY KEY AUTOINCREMENT,
        measured_at REAL NOT NULL,
        process_memory_mb INTEGER NOT NULL CHECK(process_memory_mb >= 0),
        system_load_percent INTEGER NOT NULL CHECK(system_load_percent BETWEEN 0 AND 100),
        record_tag TEXT NOT NULL)""",
}

INDEXES = {
    "ai_resource_jobs_order": "CREATE INDEX ai_resource_jobs_order ON ai_resource_jobs(state,priority DESC,created_at,id)",
    "ai_resource_media_expiry": "CREATE INDEX ai_resource_media_expiry ON ai_resource_media_leases(expires_at)",
    "ai_resource_runs_phase": "CREATE INDEX ai_resource_runs_phase ON ai_resource_runs(phase,updated_at,job_id)",
}

_V1_TABLES = {
    **{name: statement for name, statement in TABLES.items()
       if name != "ai_resource_runs"},
    "ai_resource_jobs": TABLES["ai_resource_jobs"].replace(
        "('queued','dispatching','running',\n            'cancel_requested','cancelled','completed','failed','uncertain')",
        "('queued','cancelled','completed')",
    ),
}
_V1_INDEXES = {
    name: statement for name, statement in INDEXES.items()
    if name != "ai_resource_runs_phase"
}


def _matches(actual, expected):
    return set(actual) == set(expected) and all(
        row["type"] == ("table" if name in expected and
                        expected[name].lstrip().startswith("CREATE TABLE")
                        else "index")
        and " ".join(row["sql"].split()) == " ".join(expected[name].split())
        for name, row in actual.items()
    )


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
            connection.execute("INSERT INTO metadata VALUES('ai_resource_schema','2')")
            return
        expected = TABLES | INDEXES
        if marker["value"] == "1":
            if not _matches(actual, _V1_TABLES | _V1_INDEXES):
                raise ValueError("invalid_ai_resource_storage")
            connection.execute(
                "ALTER TABLE ai_resource_jobs RENAME TO ai_resource_jobs_v1"
            )
            connection.execute(TABLES["ai_resource_jobs"])
            connection.execute(
                "INSERT INTO ai_resource_jobs SELECT * FROM ai_resource_jobs_v1"
            )
            connection.execute("DROP TABLE ai_resource_jobs_v1")
            connection.execute(TABLES["ai_resource_runs"])
            connection.execute(INDEXES["ai_resource_jobs_order"])
            connection.execute(INDEXES["ai_resource_runs_phase"])
            connection.execute(
                "UPDATE metadata SET value='2' WHERE key='ai_resource_schema'"
            )
            return
        if marker["value"] != "2" or not _matches(actual, expected):
            raise ValueError("invalid_ai_resource_storage")
    except (sqlite3.Error, TypeError, ValueError):
        raise StartupError("ai_resource_storage_invalid") from None
