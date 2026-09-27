"""Strict storage for bounded habit observations and user feedback."""

import sqlite3

from ..errors import StartupError


TABLES = {
    "habit_anomaly_observations": """CREATE TABLE habit_anomaly_observations (
        id TEXT PRIMARY KEY,
        account_id TEXT NOT NULL,
        family_id TEXT NOT NULL,
        request_key TEXT NOT NULL,
        series_id TEXT NOT NULL,
        metric TEXT NOT NULL,
        unit TEXT NOT NULL,
        value REAL NOT NULL,
        observed_at_ms INTEGER NOT NULL CHECK(observed_at_ms >= 0),
        created_at_ms INTEGER NOT NULL CHECK(created_at_ms >= 0),
        record_tag TEXT NOT NULL,
        UNIQUE(account_id,family_id,request_key))""",
    "habit_anomaly_feedback": """CREATE TABLE habit_anomaly_feedback (
        id TEXT PRIMARY KEY,
        observation_id TEXT NOT NULL REFERENCES habit_anomaly_observations(id) ON DELETE CASCADE,
        account_id TEXT NOT NULL,
        family_id TEXT NOT NULL,
        request_key TEXT NOT NULL,
        label TEXT NOT NULL CHECK(label IN ('normal','false_positive')),
        created_at_ms INTEGER NOT NULL CHECK(created_at_ms >= 0),
        record_tag TEXT NOT NULL,
        UNIQUE(account_id,family_id,request_key),
        UNIQUE(account_id,family_id,observation_id))""",
}

INDEXES = {
    "habit_anomaly_series_time":
        "CREATE INDEX habit_anomaly_series_time ON habit_anomaly_observations("
        "account_id,family_id,series_id,observed_at_ms,id)",
    "habit_anomaly_feedback_observation":
        "CREATE INDEX habit_anomaly_feedback_observation ON habit_anomaly_feedback("
        "observation_id)",
}


def migrate_habit_anomalies(connection: sqlite3.Connection) -> None:
    try:
        marker = connection.execute(
            "SELECT value FROM metadata WHERE key='habit_anomaly_schema'"
        ).fetchone()
        rows = connection.execute(
            "SELECT name,type,sql FROM sqlite_master WHERE "
            "name GLOB 'habit_anomaly*' OR tbl_name GLOB 'habit_anomaly*'"
        ).fetchall()
        actual = {row["name"]: row for row in rows if row["sql"] is not None}
        if marker is None:
            if actual:
                raise ValueError("unmarked_habit_anomaly_storage")
            for statement in TABLES.values():
                connection.execute(statement)
            for statement in INDEXES.values():
                connection.execute(statement)
            connection.execute(
                "INSERT INTO metadata VALUES('habit_anomaly_schema','1')"
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
            raise ValueError("invalid_habit_anomaly_storage")
    except (sqlite3.Error, TypeError, ValueError):
        raise StartupError("habit_anomaly_storage_invalid") from None
