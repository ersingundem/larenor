from ..errors import StartupError


def migrate_live_tv(connection):
    marker = connection.execute(
        "SELECT value FROM metadata WHERE key='live_tv_schema'"
    ).fetchone()
    names = {row["name"] for row in connection.execute(
        "SELECT name FROM sqlite_master WHERE type='table' AND "
        "name IN ('live_tv_source','live_tv_recordings')"
    ).fetchall()}
    expected = {"live_tv_source", "live_tv_recordings"}
    if marker is None:
        if names:
            raise StartupError("live_tv_schema_unsupported")
        connection.execute("""CREATE TABLE live_tv_source (
            singleton INTEGER PRIMARY KEY CHECK(singleton=1),
            revision INTEGER NOT NULL CHECK(revision>0),
            request_id TEXT NOT NULL UNIQUE CHECK(length(request_id)=32),
            request_hash TEXT NOT NULL CHECK(length(request_hash)=64),
            snapshot_json TEXT NOT NULL CHECK(length(snapshot_json)<=1048576),
            updated_at INTEGER NOT NULL
        )""")
        connection.execute("""CREATE TABLE live_tv_recordings (
            id TEXT PRIMARY KEY CHECK(length(id)=32),
            owner_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
            family_id TEXT NOT NULL CHECK(length(family_id)=32),
            actor_revision INTEGER NOT NULL CHECK(actor_revision>0),
            source_revision INTEGER NOT NULL CHECK(source_revision>0),
            provider_id TEXT NOT NULL CHECK(length(provider_id) BETWEEN 1 AND 128),
            provider_revision INTEGER NOT NULL CHECK(provider_revision>0),
            revision INTEGER NOT NULL CHECK(revision>0),
            request_id TEXT NOT NULL UNIQUE CHECK(length(request_id)=32),
            request_hash TEXT NOT NULL CHECK(length(request_hash)=64),
            programme_json TEXT NOT NULL CHECK(length(programme_json)<=4096),
            provider_recording_id TEXT NOT NULL CHECK(length(provider_recording_id) BETWEEN 1 AND 128),
            readback_revision INTEGER NOT NULL CHECK(readback_revision>0),
            state TEXT NOT NULL CHECK(state IN ('scheduled','recording','interrupted','completed','cancelled','partial','uncertain')),
            bytes_written INTEGER NOT NULL CHECK(bytes_written>=0),
            restart_count INTEGER NOT NULL CHECK(restart_count BETWEEN 0 AND 16),
            last_request_id TEXT CHECK(last_request_id IS NULL OR length(last_request_id)=32),
            last_request_hash TEXT CHECK(last_request_hash IS NULL OR length(last_request_hash)=64),
            updated_at INTEGER NOT NULL
        )""")
        connection.execute(
            "CREATE INDEX live_tv_recordings_schedule ON "
            "live_tv_recordings(state,updated_at)"
        )
        connection.execute(
            "INSERT INTO metadata(key,value) VALUES('live_tv_schema','1')"
        )
    elif marker["value"] != "1" or names != expected:
        raise StartupError("live_tv_schema_unsupported")
