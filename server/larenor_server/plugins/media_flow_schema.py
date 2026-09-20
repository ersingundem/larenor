"""Durable high-water mark for rejecting provider snapshot rollback."""


def migrate_media_flow(connection):
    connection.execute(
        "CREATE TABLE IF NOT EXISTS media_flow_high_water ("
        "media_key TEXT PRIMARY KEY NOT NULL,"
        "flow_revision INTEGER NOT NULL CHECK(flow_revision > 0),"
        "snapshot_digest TEXT NOT NULL CHECK(length(snapshot_digest) = 64),"
        "integrity_tag BLOB NOT NULL CHECK(length(integrity_tag) = 32))"
    )
