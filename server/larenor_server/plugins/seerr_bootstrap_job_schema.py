"""Additive authenticated storage for durable Seerr bootstrap jobs."""

from ..errors import StartupError


TABLE = "media_seerr_bootstraps"
_COLUMNS = (
    ("id", "TEXT", 0, None, 1),
    ("sequence", "INTEGER", 1, None, 0),
    ("revision", "INTEGER", 1, None, 0),
    ("actor_id", "TEXT", 1, None, 0),
    ("actor_revision", "INTEGER", 1, None, 0),
    ("family_id", "TEXT", 1, None, 0),
    ("request_id", "TEXT", 1, None, 0),
    ("installation_id", "TEXT", 1, None, 0),
    ("installation_revision", "INTEGER", 1, None, 0),
    ("source_bootstrap_id", "TEXT", 1, None, 0),
    ("source_bootstrap_revision", "INTEGER", 1, None, 0),
    ("state", "TEXT", 1, None, 0),
    ("phase", "TEXT", 1, None, 0),
    ("error_code", "TEXT", 0, None, 0),
    ("created_at", "INTEGER", 1, None, 0),
    ("updated_at", "INTEGER", 1, None, 0),
    ("nonce", "BLOB", 1, None, 0),
    ("ciphertext", "BLOB", 1, None, 0),
)


def _verify(connection):
    columns = tuple(
        tuple(row)
        for row in connection.execute(
            f'SELECT name,type,"notnull",dflt_value,pk FROM pragma_table_info(\'{TABLE}\')'
        )
    )
    if columns != _COLUMNS:
        raise StartupError("media_seerr_bootstraps_schema_unsupported")
    unique, dispatch = set(), False
    for index in connection.execute(f"PRAGMA index_list({TABLE})"):
        fields = tuple(
            row[0]
            for row in connection.execute(
                "SELECT name FROM pragma_index_info(?) ORDER BY seqno", (index["name"],)
            )
        )
        if index["unique"] and not index["partial"]:
            unique.add(fields)
        if index["name"] == "media_seerr_bootstraps_dispatch":
            dispatch = fields == ("state", "sequence") and not index["unique"] and not index["partial"]
    if unique != {
        ("id",),
        ("sequence",),
        ("actor_id", "request_id"),
        ("installation_id",),
    } or not dispatch:
        raise StartupError("media_seerr_bootstraps_schema_unsupported")
    foreign = {
        tuple(row)
        for row in connection.execute(
            f'SELECT "table","from","to",on_update,on_delete,match '
            f"FROM pragma_foreign_key_list('{TABLE}')"
        )
    }
    if foreign != {
        ("media_installations", "installation_id", "id", "NO ACTION", "NO ACTION", "NONE"),
        (
            "media_service_bootstraps",
            "source_bootstrap_id",
            "id",
            "NO ACTION",
            "NO ACTION",
            "NONE",
        ),
    }:
        raise StartupError("media_seerr_bootstraps_schema_unsupported")


def migrate_seerr_bootstraps(connection):
    marker = connection.execute(
        "SELECT value FROM metadata WHERE key='media_seerr_bootstraps_schema'"
    ).fetchone()
    tables = {
        row[0]
        for row in connection.execute(
            "SELECT name FROM sqlite_master WHERE type='table' "
            "AND name LIKE 'media_seerr_bootstrap%'"
        )
    }
    if marker is None:
        if tables:
            raise StartupError("media_seerr_bootstraps_schema_unsupported")
        connection.execute(
            f"""CREATE TABLE {TABLE} (
                id TEXT PRIMARY KEY,
                sequence INTEGER NOT NULL UNIQUE CHECK(sequence > 0),
                revision INTEGER NOT NULL CHECK(revision > 0),
                actor_id TEXT NOT NULL,
                actor_revision INTEGER NOT NULL CHECK(actor_revision > 0),
                family_id TEXT NOT NULL,
                request_id TEXT NOT NULL,
                installation_id TEXT NOT NULL UNIQUE REFERENCES media_installations(id),
                installation_revision INTEGER NOT NULL CHECK(installation_revision > 0),
                source_bootstrap_id TEXT NOT NULL REFERENCES media_service_bootstraps(id),
                source_bootstrap_revision INTEGER NOT NULL CHECK(source_bootstrap_revision > 0),
                state TEXT NOT NULL CHECK(state IN ('queued','running','succeeded','needs_attention','failed','cancelled')),
                phase TEXT NOT NULL CHECK(phase IN ('queued','bootstrapping','complete')),
                error_code TEXT,
                created_at INTEGER NOT NULL,
                updated_at INTEGER NOT NULL,
                nonce BLOB NOT NULL,
                ciphertext BLOB NOT NULL,
                UNIQUE(actor_id,request_id)
            )"""
        )
        connection.execute(
            f"CREATE INDEX media_seerr_bootstraps_dispatch ON {TABLE}(state,sequence)"
        )
        connection.execute(
            "INSERT INTO metadata(key,value) VALUES('media_seerr_bootstraps_schema','1')"
        )
    elif marker["value"] != "1" or tables != {TABLE}:
        raise StartupError("media_seerr_bootstraps_schema_unsupported")
    _verify(connection)

