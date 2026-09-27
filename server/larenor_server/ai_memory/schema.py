"""Durable schema for time-bounded AI memory and deletion tombstones."""

import sqlite3

from ..errors import StartupError


TABLES = {
    "ai_memory_records": """CREATE TABLE ai_memory_records (
        id TEXT PRIMARY KEY NOT NULL CHECK(length(id)=32),
        core_id TEXT NOT NULL CHECK(length(core_id)=32),
        home_id TEXT NOT NULL CHECK(length(home_id)=32),
        account_id TEXT NOT NULL CHECK(length(account_id)=32),
        revision INTEGER NOT NULL CHECK(revision>0),
        source_kind TEXT NOT NULL CHECK(source_kind IN ('manual','assistant','automation','integration')),
        source_description TEXT NOT NULL CHECK(length(source_description) BETWEEN 1 AND 160),
        content TEXT NOT NULL CHECK(length(content) BETWEEN 1 AND 2048),
        learned_by TEXT NOT NULL CHECK(length(learned_by) BETWEEN 1 AND 80),
        created_at REAL NOT NULL CHECK(created_at>=0),
        updated_at REAL NOT NULL CHECK(updated_at>=created_at),
        expires_at REAL NOT NULL CHECK(expires_at>created_at),
        record_tag TEXT NOT NULL CHECK(length(record_tag)=64))""",
    "ai_memory_tombstones": """CREATE TABLE ai_memory_tombstones (
        memory_id TEXT PRIMARY KEY NOT NULL CHECK(length(memory_id)=32),
        core_id TEXT NOT NULL CHECK(length(core_id)=32),
        home_id TEXT NOT NULL CHECK(length(home_id)=32),
        account_id TEXT NOT NULL CHECK(length(account_id)=32),
        deleted_revision INTEGER NOT NULL CHECK(deleted_revision>0),
        deleted_at REAL NOT NULL CHECK(deleted_at>=0),
        reason TEXT NOT NULL CHECK(reason IN ('userRequested','privacy','obsolete','incorrect','expired')),
        record_tag TEXT NOT NULL CHECK(length(record_tag)=64))""",
    "ai_memory_index": """CREATE TABLE ai_memory_index (
        memory_id TEXT NOT NULL REFERENCES ai_memory_records(id) ON DELETE CASCADE,
        token_hash TEXT NOT NULL CHECK(length(token_hash)=64),
        position INTEGER NOT NULL CHECK(position>=0),
        record_tag TEXT NOT NULL CHECK(length(record_tag)=64),
        PRIMARY KEY(memory_id,token_hash,position))""",
    "ai_memory_cache": """CREATE TABLE ai_memory_cache (
        cache_key TEXT PRIMARY KEY NOT NULL CHECK(length(cache_key)=64),
        core_id TEXT NOT NULL CHECK(length(core_id)=32),
        home_id TEXT NOT NULL CHECK(length(home_id)=32),
        account_id TEXT NOT NULL CHECK(length(account_id)=32),
        result_json TEXT NOT NULL CHECK(length(result_json)<=16384),
        expires_at REAL NOT NULL CHECK(expires_at>=0),
        record_tag TEXT NOT NULL CHECK(length(record_tag)=64))""",
    "ai_memory_mutations": """CREATE TABLE ai_memory_mutations (
        core_id TEXT NOT NULL CHECK(length(core_id)=32),
        home_id TEXT NOT NULL CHECK(length(home_id)=32),
        account_id TEXT NOT NULL CHECK(length(account_id)=32),
        request_key TEXT NOT NULL CHECK(length(request_key) BETWEEN 16 AND 128),
        action TEXT NOT NULL CHECK(action IN ('remember','correct','forget','restore')),
        request_hash TEXT NOT NULL CHECK(length(request_hash)=64),
        result_json TEXT NOT NULL CHECK(length(result_json)<=16384),
        created_at REAL NOT NULL CHECK(created_at>=0),
        record_tag TEXT NOT NULL CHECK(length(record_tag)=64),
        PRIMARY KEY(core_id,home_id,account_id,request_key))""",
}

INDEXES = {
    "ai_memory_scope_expiry": "CREATE INDEX ai_memory_scope_expiry ON ai_memory_records(core_id,home_id,account_id,expires_at,id)",
    "ai_memory_token_lookup": "CREATE INDEX ai_memory_token_lookup ON ai_memory_index(token_hash,memory_id)",
    "ai_memory_tombstone_scope": "CREATE INDEX ai_memory_tombstone_scope ON ai_memory_tombstones(core_id,home_id,account_id,deleted_at,memory_id)",
    "ai_memory_cache_scope": "CREATE INDEX ai_memory_cache_scope ON ai_memory_cache(core_id,home_id,account_id,expires_at)",
    "ai_memory_mutation_age": "CREATE INDEX ai_memory_mutation_age ON ai_memory_mutations(created_at)",
}


def migrate_ai_memory(connection: sqlite3.Connection) -> None:
    try:
        marker = connection.execute(
            "SELECT value FROM metadata WHERE key='ai_memory_schema'"
        ).fetchone()
        rows = connection.execute(
            "SELECT name,type,sql FROM sqlite_master WHERE "
            "name GLOB 'ai_memory_*' OR tbl_name GLOB 'ai_memory_*'"
        ).fetchall()
        actual = {row["name"]: row for row in rows if row["sql"] is not None}
        if marker is None:
            if actual:
                raise ValueError("unmarked_ai_memory_storage")
            for statement in TABLES.values():
                connection.execute(statement)
            for statement in INDEXES.values():
                connection.execute(statement)
            connection.execute(
                "INSERT INTO metadata(key,value) VALUES('ai_memory_schema','1')"
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
            raise ValueError("invalid_ai_memory_storage")
    except (sqlite3.Error, TypeError, ValueError):
        raise StartupError("ai_memory_storage_invalid") from None
