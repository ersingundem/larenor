"""Additive durable jobs schema, independent of expiring preview retention."""

import sqlite3

from ..errors import StartupError


TABLES = {"plugin_jobs", "plugin_job_events"}
JOBS = """CREATE TABLE plugin_jobs (
    id TEXT PRIMARY KEY,
    sequence INTEGER NOT NULL UNIQUE CHECK(sequence > 0),
    revision INTEGER NOT NULL CHECK(revision > 0),
    actor_id TEXT NOT NULL,
    actor_revision INTEGER NOT NULL CHECK(actor_revision > 0),
    family_id TEXT NOT NULL,
    request_id TEXT NOT NULL,
    preview_id TEXT NOT NULL UNIQUE,
    state TEXT NOT NULL CHECK(state IN ('queued','running','succeeded','failed','cancelled','needs_attention')),
    phase TEXT NOT NULL CHECK(phase IN ('queued','checking_requirements','complete')),
    cancel_requested INTEGER NOT NULL CHECK(cancel_requested IN (0,1)),
    error_code TEXT,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL,
    nonce BLOB NOT NULL,
    ciphertext BLOB NOT NULL,
    UNIQUE(actor_id, request_id)
)"""
EVENTS = """CREATE TABLE plugin_job_events (
    sequence INTEGER PRIMARY KEY AUTOINCREMENT,
    job_id TEXT NOT NULL REFERENCES plugin_jobs(id),
    job_revision INTEGER NOT NULL CHECK(job_revision > 0),
    code TEXT NOT NULL,
    created_at INTEGER NOT NULL,
    nonce BLOB NOT NULL,
    ciphertext BLOB NOT NULL,
    UNIQUE(job_id, job_revision)
)"""


def migrate_plugin_jobs(connection: sqlite3.Connection) -> None:
    marker = connection.execute("SELECT value FROM metadata WHERE key='plugin_jobs_schema'").fetchone()
    tables = {row[0] for row in connection.execute(
        "SELECT name FROM sqlite_master WHERE type='table' AND (name='plugin_jobs' OR name LIKE 'plugin_job_%')")}
    if marker is None:
        if tables:
            raise StartupError("plugin_jobs_schema_unsupported")
        connection.execute(JOBS)
        connection.execute(EVENTS)
        connection.execute("CREATE UNIQUE INDEX plugin_jobs_one_running ON plugin_jobs((1)) WHERE state='running'")
        connection.execute("CREATE INDEX plugin_jobs_dispatch ON plugin_jobs(state,sequence)")
        connection.execute("CREATE INDEX plugin_job_events_job ON plugin_job_events(job_id,sequence)")
        connection.execute("INSERT INTO metadata(key,value) VALUES('plugin_jobs_schema','1')")
    elif marker["value"] != "1" or tables != TABLES:
        raise StartupError("plugin_jobs_schema_unsupported")
