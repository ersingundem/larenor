import sqlite3

from ..errors import StartupError


MAX_PRINTERS = 64
MAX_INTENTS = 10_000

TABLES = {
    "workshop_printers": """CREATE TABLE workshop_printers (
        id TEXT PRIMARY KEY,
        owner_id TEXT NOT NULL,
        family_id TEXT NOT NULL,
        revision INTEGER NOT NULL CHECK(revision > 0),
        service_id TEXT NOT NULL,
        service_revision INTEGER NOT NULL CHECK(service_revision > 0),
        name TEXT NOT NULL,
        job_revision INTEGER NOT NULL CHECK(job_revision > 0),
        job_id TEXT,
        job_state TEXT NOT NULL CHECK(job_state IN ('idle','printing','paused','completed','error')),
        progress_permille INTEGER NOT NULL CHECK(progress_permille BETWEEN 0 AND 1000),
        remaining_seconds INTEGER,
        material_revision INTEGER NOT NULL CHECK(material_revision > 0),
        material_kind TEXT NOT NULL CHECK(material_kind IN ('pla','petg','abs','tpu','asa','other')),
        remaining_grams REAL NOT NULL CHECK(remaining_grams >= 0),
        safety_revision INTEGER NOT NULL CHECK(safety_revision > 0),
        connectivity TEXT NOT NULL CHECK(connectivity IN ('online','offline')),
        thermal TEXT NOT NULL CHECK(thermal IN ('normal','warning','runaway')),
        filament TEXT NOT NULL CHECK(filament IN ('available','low','runout','unknown')),
        door TEXT NOT NULL CHECK(door IN ('closed','open','unknown')),
        emergency TEXT NOT NULL CHECK(emergency IN ('clear','triggered')),
        observed_at REAL NOT NULL,
        updated_at REAL NOT NULL,
        envelope_tag TEXT NOT NULL)""",
    "workshop_intents": """CREATE TABLE workshop_intents (
        sequence INTEGER PRIMARY KEY AUTOINCREMENT,
        id TEXT NOT NULL UNIQUE,
        printer_id TEXT NOT NULL,
        actor_id TEXT NOT NULL,
        request_key TEXT NOT NULL,
        action TEXT NOT NULL CHECK(action IN ('pause','cancel')),
        printer_revision INTEGER NOT NULL CHECK(printer_revision > 0),
        service_revision INTEGER NOT NULL CHECK(service_revision > 0),
        job_revision INTEGER NOT NULL CHECK(job_revision > 0),
        material_revision INTEGER NOT NULL CHECK(material_revision > 0),
        safety_revision INTEGER NOT NULL CHECK(safety_revision > 0),
        state TEXT NOT NULL CHECK(state='recorded'),
        effect TEXT NOT NULL CHECK(effect='notDispatched'),
        created_at REAL NOT NULL,
        envelope_tag TEXT NOT NULL,
        UNIQUE(printer_id,request_key),
        FOREIGN KEY(printer_id) REFERENCES workshop_printers(id) ON DELETE CASCADE)""",
}


def migrate_workshop(connection: sqlite3.Connection) -> None:
    try:
        marker = connection.execute(
            "SELECT value FROM metadata WHERE key='workshop_schema'"
        ).fetchone()
        rows = connection.execute(
            "SELECT name,type,tbl_name,sql FROM sqlite_master "
            "WHERE name GLOB 'workshop_*' OR tbl_name GLOB 'workshop_*'"
        ).fetchall()
        actual = {row["name"]: row for row in rows}
        implicit = {
            name: row for name, row in list(actual.items())
            if row["type"] == "index" and row["sql"] is None
        }
        for name in implicit:
            actual.pop(name)
        if marker is None:
            if actual or implicit:
                raise ValueError("unmarked_workshop")
            for statement in TABLES.values():
                connection.execute(statement)
            connection.execute(
                "INSERT INTO metadata VALUES('workshop_schema','1')"
            )
            return
        if marker["value"] != "1" or set(actual) != set(TABLES) or any(
            row["type"] != "table"
            or " ".join(row["sql"].split()) != " ".join(TABLES[name].split())
            for name, row in actual.items()
        ):
            raise ValueError("invalid_workshop")
        expected_indexes = {"workshop_printers": 1, "workshop_intents": 2}
        for table, count in expected_indexes.items():
            indexes = connection.execute(f"PRAGMA index_list({table})").fetchall()
            if len(indexes) != count or any(
                row["origin"] not in {"pk", "u"} for row in indexes
            ):
                raise ValueError("invalid_workshop_indexes")
    except (ValueError, TypeError, sqlite3.Error):
        raise StartupError("workshop_storage_invalid") from None
