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
        source TEXT NOT NULL CHECK(source IN ('synthetic','real')),
        evidence_json TEXT,
        evidence_tag TEXT,
        record_tag TEXT NOT NULL,
        CHECK((source='synthetic' AND evidence_json IS NULL AND evidence_tag IS NULL) OR
              (source='real' AND evidence_json IS NOT NULL AND evidence_tag IS NOT NULL)),
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

V1_OBSERVATIONS = """CREATE TABLE habit_anomaly_observations (
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
        UNIQUE(account_id,family_id,request_key))"""

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
                "INSERT INTO metadata VALUES('habit_anomaly_schema','2')"
            )
            return
        expected = TABLES | INDEXES
        if marker["value"] == "1":
            old_expected = {
                **TABLES,
                "habit_anomaly_observations": V1_OBSERVATIONS,
            } | INDEXES
            if (
                set(actual) != set(old_expected)
                or any(
                    row["type"] != ("table" if name in TABLES else "index")
                    or " ".join(row["sql"].split())
                    != " ".join(old_expected[name].split())
                    for name, row in actual.items()
                )
            ):
                raise ValueError("invalid_habit_anomaly_storage")
            feedback = [tuple(row) for row in connection.execute(
                "SELECT * FROM habit_anomaly_feedback ORDER BY id"
            )]
            connection.execute("DROP INDEX habit_anomaly_feedback_observation")
            connection.execute("DROP INDEX habit_anomaly_series_time")
            connection.execute("DROP TABLE habit_anomaly_feedback")
            connection.execute(
                "ALTER TABLE habit_anomaly_observations RENAME TO "
                "habit_anomaly_observations_v1"
            )
            connection.execute(TABLES["habit_anomaly_observations"])
            connection.execute(
                "INSERT INTO habit_anomaly_observations "
                "SELECT id,account_id,family_id,request_key,series_id,metric,unit,"
                "value,observed_at_ms,created_at_ms,'synthetic',NULL,NULL,record_tag "
                "FROM habit_anomaly_observations_v1"
            )
            connection.execute(TABLES["habit_anomaly_feedback"])
            connection.executemany(
                "INSERT INTO habit_anomaly_feedback VALUES(?,?,?,?,?,?,?,?)",
                feedback,
            )
            connection.execute("DROP TABLE habit_anomaly_observations_v1")
            for statement in INDEXES.values():
                connection.execute(statement)
            connection.execute(
                "UPDATE metadata SET value='2' WHERE key='habit_anomaly_schema'"
            )
            return
        if (
            marker["value"] != "2"
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
