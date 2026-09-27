"""Bounded durable schema for evidence-bound media archive actions."""

import sqlite3

from ..errors import StartupError


POLICY = """CREATE TABLE media_archive_action_policy (
    singleton INTEGER PRIMARY KEY CHECK(singleton=1),
    revision INTEGER NOT NULL CHECK(revision>0),
    quota_bytes INTEGER NOT NULL CHECK(quota_bytes BETWEEN 268435456 AND 10995116277760),
    request_id TEXT CHECK(request_id IS NULL OR length(request_id)=32),
    request_hash TEXT CHECK(request_hash IS NULL OR length(request_hash)=64),
    created_at INTEGER NOT NULL CHECK(created_at>0),
    updated_at INTEGER NOT NULL CHECK(updated_at>=created_at),
    envelope_tag TEXT NOT NULL CHECK(length(envelope_tag)=64)
)"""

PREVIEWS = """CREATE TABLE media_archive_action_previews (
    id TEXT PRIMARY KEY NOT NULL CHECK(length(id)=32),
    sequence INTEGER NOT NULL UNIQUE CHECK(sequence>0),
    revision INTEGER NOT NULL CHECK(revision>0),
    actor_id TEXT NOT NULL CHECK(length(actor_id)=32),
    actor_revision INTEGER NOT NULL CHECK(actor_revision>0),
    family_id TEXT NOT NULL CHECK(length(family_id)=32),
    request_id TEXT NOT NULL CHECK(length(request_id)=32),
    request_hash TEXT NOT NULL CHECK(length(request_hash)=64),
    kind TEXT NOT NULL CHECK(kind IN ('optimize','cleanup')),
    candidate_id TEXT NOT NULL CHECK(length(candidate_id)=64),
    source_job_id TEXT CHECK(source_job_id IS NULL OR length(source_job_id)=32),
    source_job_revision INTEGER CHECK(source_job_revision IS NULL OR source_job_revision>0),
    policy_revision INTEGER NOT NULL CHECK(policy_revision>0),
    installation_id TEXT NOT NULL CHECK(length(installation_id)=32),
    installation_revision INTEGER NOT NULL CHECK(installation_revision>0),
    snapshot_revision INTEGER NOT NULL CHECK(snapshot_revision>0),
    operation TEXT NOT NULL CHECK(operation IN ('stage_transcode','cleanup_duplicate','cleanup_retention','cleanup_retained_original')),
    state TEXT NOT NULL CHECK(state IN ('ready','consumed','expired')),
    command_json TEXT NOT NULL CHECK(length(command_json)<=262144),
    reserved_bytes INTEGER NOT NULL CHECK(reserved_bytes>=0),
    expires_at INTEGER NOT NULL CHECK(expires_at>0),
    created_at INTEGER NOT NULL CHECK(created_at>0),
    updated_at INTEGER NOT NULL CHECK(updated_at>=created_at),
    envelope_tag TEXT NOT NULL CHECK(length(envelope_tag)=64),
    UNIQUE(actor_id,family_id,request_id)
)"""

JOBS = """CREATE TABLE media_archive_action_jobs (
    id TEXT PRIMARY KEY NOT NULL CHECK(length(id)=32),
    sequence INTEGER NOT NULL UNIQUE CHECK(sequence>0),
    revision INTEGER NOT NULL CHECK(revision>0),
    actor_id TEXT NOT NULL CHECK(length(actor_id)=32),
    actor_revision INTEGER NOT NULL CHECK(actor_revision>0),
    family_id TEXT NOT NULL CHECK(length(family_id)=32),
    request_id TEXT NOT NULL CHECK(length(request_id)=32),
    request_hash TEXT NOT NULL CHECK(length(request_hash)=64),
    preview_id TEXT NOT NULL UNIQUE CHECK(length(preview_id)=32),
    kind TEXT NOT NULL CHECK(kind IN ('optimize','cleanup')),
    candidate_id TEXT NOT NULL CHECK(length(candidate_id)=64),
    source_job_id TEXT CHECK(source_job_id IS NULL OR length(source_job_id)=32),
    source_job_revision INTEGER CHECK(source_job_revision IS NULL OR source_job_revision>0),
    state TEXT NOT NULL CHECK(state IN ('queued','running','succeeded','failed','cancelled','needs_attention')),
    phase TEXT NOT NULL CHECK(phase IN ('queued','preparing','executing','verifying','complete','failed','cancelled','needs_attention')),
    cancel_requested INTEGER NOT NULL CHECK(cancel_requested IN (0,1)),
    reserved_bytes INTEGER NOT NULL CHECK(reserved_bytes>=0),
    retained_original INTEGER NOT NULL CHECK(retained_original IN (0,1)),
    error_code TEXT CHECK(error_code IS NULL OR error_code IN ('worker_unavailable','authority_changed','evidence_changed','effect_unknown','verification_failed','cancel_unknown')),
    proof_digest TEXT CHECK(proof_digest IS NULL OR length(proof_digest)=64),
    command_json TEXT NOT NULL CHECK(length(command_json)<=262144),
    created_at INTEGER NOT NULL CHECK(created_at>0),
    updated_at INTEGER NOT NULL CHECK(updated_at>=created_at),
    envelope_tag TEXT NOT NULL CHECK(length(envelope_tag)=64),
    UNIQUE(actor_id,family_id,request_id),
    UNIQUE(source_job_id)
)"""

PREVIEW_EXPIRY_INDEX = """CREATE INDEX media_archive_action_preview_expiry
    ON media_archive_action_previews(state,expires_at,sequence)"""
JOB_STATE_INDEX = """CREATE INDEX media_archive_action_job_state
    ON media_archive_action_jobs(state,sequence)"""


def _normal(value):
    return " ".join(value.split()) if type(value) is str else None


def migrate_media_archive_actions(connection: sqlite3.Connection) -> None:
    """Create or exact-validate the F30 action schema."""
    try:
        marker = connection.execute(
            "SELECT value FROM metadata "
            "WHERE key='media_archive_actions_schema'"
        ).fetchone()
        names = {
            "media_archive_action_policy": POLICY,
            "media_archive_action_previews": PREVIEWS,
            "media_archive_action_jobs": JOBS,
            "media_archive_action_preview_expiry": PREVIEW_EXPIRY_INDEX,
            "media_archive_action_job_state": JOB_STATE_INDEX,
        }
        rows = connection.execute(
            "SELECT name,sql FROM sqlite_master WHERE name IN (?,?,?,?,?)",
            tuple(names),
        ).fetchall()
        actual = {row["name"]: row["sql"] for row in rows}
        if marker is None:
            if actual:
                raise ValueError("unmarked_media_archive_actions")
            for statement in names.values():
                connection.execute(statement)
            connection.execute(
                "INSERT INTO metadata(key,value) VALUES"
                "('media_archive_actions_schema','1')"
            )
            return
        if (marker["value"] != "1" or set(actual) != set(names)
                or any(_normal(actual[name]) != _normal(statement)
                       for name, statement in names.items())):
            raise ValueError("invalid_media_archive_actions")
    except (ValueError, TypeError, sqlite3.Error):
        raise StartupError("media_archive_action_schema_unsupported") from None
