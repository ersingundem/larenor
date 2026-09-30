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
        thermal TEXT NOT NULL CHECK(thermal IN ('normal','warning','runaway','unknown')),
        filament TEXT NOT NULL CHECK(filament IN ('available','low','runout','unknown')),
        door TEXT NOT NULL CHECK(door IN ('closed','open','unknown')),
        emergency TEXT NOT NULL CHECK(emergency IN ('clear','triggered','unknown')),
        observed_at REAL NOT NULL,
        temperature_revision INTEGER NOT NULL CHECK(temperature_revision > 0),
        temperatures_json TEXT NOT NULL,
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
    "workshop_effects": """CREATE TABLE workshop_effects (
        intent_id TEXT PRIMARY KEY,
        command_id TEXT NOT NULL UNIQUE,
        status TEXT NOT NULL CHECK(status IN ('applied','unknown')),
        code TEXT NOT NULL CHECK(code IN ('applied','readback_mismatch','worker_ack_unknown')),
        provider_revision INTEGER NOT NULL CHECK(provider_revision > 0),
        readback_json TEXT,
        created_at REAL NOT NULL,
        envelope_tag TEXT NOT NULL,
        FOREIGN KEY(intent_id) REFERENCES workshop_intents(id) ON DELETE CASCADE)""",
}

V2_TABLES = {
    **TABLES,
    "workshop_printers": TABLES["workshop_printers"]
    .replace(
        "thermal IN ('normal','warning','runaway','unknown')",
        "thermal IN ('normal','warning','runaway')",
    )
    .replace(
        "emergency IN ('clear','triggered','unknown')",
        "emergency IN ('clear','triggered')",
    )
    .replace(
        "        temperature_revision INTEGER NOT NULL CHECK(temperature_revision > 0),\n"
        "        temperatures_json TEXT NOT NULL,\n",
        "",
    ),
}


def _schema_objects(connection):
    rows = connection.execute(
        "SELECT name,type,tbl_name,sql FROM sqlite_master "
        "WHERE name GLOB 'workshop_*' OR tbl_name GLOB 'workshop_*'"
    ).fetchall()
    actual = {row["name"]: row for row in rows}
    implicit = {
        name: row
        for name, row in list(actual.items())
        if row["type"] == "index" and row["sql"] is None
    }
    for name in implicit:
        actual.pop(name)
    return actual, implicit


def _valid_tables(actual, expected):
    return set(actual) == set(expected) and all(
        row["type"] == "table"
        and " ".join(row["sql"].split()) == " ".join(expected[name].split())
        for name, row in actual.items()
    )


def _valid_indexes(connection, tables):
    expected = {
        "workshop_printers": 1,
        "workshop_intents": 2,
        "workshop_effects": 2,
    }
    for table in tables:
        indexes = connection.execute(f"PRAGMA index_list({table})").fetchall()
        if len(indexes) != expected[table] or any(
            row["origin"] not in {"pk", "u"} for row in indexes
        ):
            return False
    return True


def _rebuild_v3(connection):
    order = tuple(TABLES)
    temporary = {name: name + "_v3_copy" for name in order}
    for name in order:
        statement = TABLES[name].replace(
            f"CREATE TABLE {name}", f"CREATE TABLE {temporary[name]}", 1
        )
        for parent, replacement in temporary.items():
            statement = statement.replace(
                f"REFERENCES {parent}(", f"REFERENCES {replacement}("
            )
        connection.execute(statement)
        if name == "workshop_printers":
            columns = [
                row["name"]
                for row in connection.execute(
                    f"PRAGMA table_info({name})"
                ).fetchall()
            ]
            selected = ",".join(columns)
            connection.execute(
                f"INSERT INTO {temporary[name]} ({selected},temperature_revision,"
                f"temperatures_json) SELECT {selected},1,'[]' FROM {name}"
            )
        else:
            connection.execute(f"INSERT INTO {temporary[name]} SELECT * FROM {name}")
    for name in reversed(order):
        connection.execute(f"DROP TABLE {name}")
    for statement in TABLES.values():
        connection.execute(statement)
    for name in order:
        connection.execute(f"INSERT INTO {name} SELECT * FROM {temporary[name]}")
    for name in reversed(order):
        connection.execute(f"DROP TABLE {temporary[name]}")


def migrate_workshop(connection: sqlite3.Connection) -> None:
    try:
        marker = connection.execute(
            "SELECT value FROM metadata WHERE key='workshop_schema'"
        ).fetchone()
        actual, implicit = _schema_objects(connection)
        if marker is None:
            if actual or implicit:
                raise ValueError("unmarked_workshop")
            for statement in TABLES.values():
                connection.execute(statement)
            connection.execute(
                "INSERT INTO metadata VALUES('workshop_schema','3')"
            )
            return
        if marker["value"] == "1":
            legacy = {
                name: statement
                for name, statement in V2_TABLES.items()
                if name != "workshop_effects"
            }
            if not _valid_tables(actual, legacy) or not _valid_indexes(
                connection, legacy
            ):
                raise ValueError("invalid_workshop")
            connection.execute(V2_TABLES["workshop_effects"])
            connection.execute(
                "UPDATE metadata SET value='2' WHERE key='workshop_schema'"
            )
            marker = {"value": "2"}
            actual, _implicit = _schema_objects(connection)
        if marker["value"] == "2":
            if not _valid_tables(actual, V2_TABLES) or not _valid_indexes(
                connection, V2_TABLES
            ):
                raise ValueError("invalid_workshop")
            _rebuild_v3(connection)
            connection.execute(
                "UPDATE metadata SET value='3' WHERE key='workshop_schema'"
            )
            marker = {"value": "3"}
            actual, _implicit = _schema_objects(connection)
        if (
            marker["value"] != "3"
            or not _valid_tables(actual, TABLES)
            or not _valid_indexes(connection, TABLES)
        ):
            raise ValueError("invalid_workshop")
    except (ValueError, TypeError, sqlite3.Error):
        raise StartupError("workshop_storage_invalid") from None
