import sqlite3

from ..errors import StartupError


TABLES = {
    "automation_trials": """CREATE TABLE automation_trials (
        id TEXT PRIMARY KEY, account_id TEXT NOT NULL, family_id TEXT NOT NULL,
        request_key TEXT NOT NULL, timezone TEXT NOT NULL, local_start_date TEXT NOT NULL,
        starts_at_ms INTEGER NOT NULL, ends_at_ms INTEGER NOT NULL,
        rules_json TEXT NOT NULL, created_at_ms INTEGER NOT NULL, record_tag TEXT NOT NULL,
        UNIQUE(account_id,family_id,request_key))""",
    "automation_trial_events": """CREATE TABLE automation_trial_events (
        id TEXT PRIMARY KEY, trial_id TEXT NOT NULL REFERENCES automation_trials(id) ON DELETE CASCADE,
        account_id TEXT NOT NULL, family_id TEXT NOT NULL, request_key TEXT NOT NULL,
        source TEXT NOT NULL CHECK(source IN ('real','synthetic')), event_key TEXT NOT NULL,
        occurred_at_ms INTEGER NOT NULL, result_json TEXT NOT NULL,
        created_at_ms INTEGER NOT NULL, record_tag TEXT NOT NULL,
        UNIQUE(account_id,family_id,request_key))""",
}
INDEXES = {
    "automation_trial_owner": "CREATE INDEX automation_trial_owner ON automation_trials(account_id,family_id,created_at_ms,id)",
    "automation_trial_event_order": "CREATE INDEX automation_trial_event_order ON automation_trial_events(trial_id,occurred_at_ms,id)",
}


def migrate_automation_trials(connection: sqlite3.Connection) -> None:
    try:
        marker = connection.execute(
            "SELECT value FROM metadata WHERE key='automation_trial_schema'"
        ).fetchone()
        rows = connection.execute(
            "SELECT name,type,sql FROM sqlite_master WHERE "
            "name GLOB 'automation_trial*' OR tbl_name GLOB 'automation_trial*'"
        ).fetchall()
        actual = {row["name"]: row for row in rows if row["sql"] is not None}
        if marker is None:
            if actual:
                raise ValueError("unmarked_automation_trial_storage")
            for statement in TABLES.values():
                connection.execute(statement)
            for statement in INDEXES.values():
                connection.execute(statement)
            connection.execute("INSERT INTO metadata VALUES('automation_trial_schema','1')")
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
            raise ValueError("invalid_automation_trial_storage")
    except (sqlite3.Error, TypeError, ValueError):
        raise StartupError("automation_trial_storage_invalid") from None
