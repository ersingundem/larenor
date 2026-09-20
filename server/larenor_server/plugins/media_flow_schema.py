"""Durable high-water mark for rejecting provider snapshot rollback."""


def migrate_media_flow(connection):
    connection.execute(
        "CREATE TABLE IF NOT EXISTS media_flow_high_water ("
        "media_key TEXT PRIMARY KEY NOT NULL,"
        "flow_revision INTEGER NOT NULL CHECK(flow_revision > 0),"
        "snapshot_digest TEXT NOT NULL CHECK(length(snapshot_digest) = 64),"
        "integrity_tag BLOB NOT NULL CHECK(length(integrity_tag) = 32))"
    )
    connection.execute(
        "CREATE TABLE IF NOT EXISTS media_flow_delivery_journal ("
        "media_key TEXT PRIMARY KEY NOT NULL,"
        "operation_id TEXT NOT NULL CHECK(length(operation_id) = 32),"
        "request_receipt_id TEXT NOT NULL "
        "CHECK(length(request_receipt_id) = 32),"
        "latest_attempt INTEGER NOT NULL "
        "CHECK(latest_attempt BETWEEN 1 AND 32),"
        "integrity_tag BLOB NOT NULL CHECK(length(integrity_tag) = 32))"
    )
    connection.execute(
        "CREATE TABLE IF NOT EXISTS media_flow_file_journal ("
        "flow_media_key TEXT NOT NULL,"
        "item_media_key TEXT NOT NULL,"
        "identity_digest TEXT NOT NULL CHECK(length(identity_digest) = 64),"
        "integrity_tag BLOB NOT NULL CHECK(length(integrity_tag) = 32),"
        "PRIMARY KEY(flow_media_key,item_media_key))"
    )
