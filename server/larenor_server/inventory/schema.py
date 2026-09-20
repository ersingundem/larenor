import hashlib
import hmac
import json
import sqlite3

from ..errors import StartupError


MAX_ITEMS = 1000
MAX_AUDIT = 10000
TABLE = """CREATE TABLE inventory_items (
    id TEXT PRIMARY KEY,
    revision INTEGER NOT NULL CHECK(revision > 0),
    created_by TEXT NOT NULL,
    nonce BLOB NOT NULL,
    ciphertext BLOB NOT NULL)"""
AUDIT = """CREATE TABLE inventory_audit (
    sequence INTEGER PRIMARY KEY AUTOINCREMENT,
    item_id TEXT NOT NULL,
    action TEXT NOT NULL,
    actor_id TEXT NOT NULL,
    item_revision INTEGER NOT NULL,
    created_at REAL NOT NULL,
    previous_hash TEXT NOT NULL,
    entry_hash TEXT NOT NULL)"""
AUDIT_STATE = """CREATE TABLE inventory_audit_state (
    singleton INTEGER PRIMARY KEY CHECK(singleton=1),
    sequence INTEGER NOT NULL,
    head_hash TEXT NOT NULL,
    authentication_tag TEXT NOT NULL)"""


def state_tag(key, scope, sequence, head):
    payload = json.dumps(
        [scope.coreId, scope.homeId, sequence, head],
        separators=(",", ":"),
    ).encode("ascii")
    return hmac.new(key, b"larenor:inventory-audit-state:v1\0" + payload, hashlib.sha256).hexdigest()


def entry_hash(key, scope, sequence, item_id, action, actor_id, revision, created_at, previous):
    payload = json.dumps(
        [scope.coreId, scope.homeId, sequence, item_id, action, actor_id, revision,
         created_at, previous], separators=(",", ":"), allow_nan=False,
    ).encode("ascii")
    return hmac.new(key, b"larenor:inventory-audit-entry:v1\0" + payload, hashlib.sha256).hexdigest()


def migrate_inventory(connection, key, scope):
    try:
        marker = connection.execute(
            "SELECT value FROM metadata WHERE key='inventory_schema'"
        ).fetchone()
        rows = connection.execute(
            "SELECT name,type,tbl_name,sql FROM sqlite_master "
            "WHERE name GLOB 'inventory_*' OR tbl_name='inventory_items'"
        ).fetchall()
        by_name = {row["name"]: row for row in rows}
        if marker is None:
            if by_name:
                raise ValueError("unmarked_inventory")
            connection.execute(TABLE)
            connection.execute(AUDIT)
            connection.execute(AUDIT_STATE)
            head = '0' * 64
            connection.execute("INSERT INTO inventory_audit_state VALUES(1,0,?,?)", (
                head, state_tag(key, scope, 0, head)))
            connection.execute("INSERT INTO metadata VALUES('inventory_schema','2')")
            return
        table = by_name.pop("inventory_items", None)
        index = by_name.pop("sqlite_autoindex_inventory_items_1", None)
        if (
            marker["value"] != "2"
            or table is None
            or table["type"] != "table"
            or " ".join(table["sql"].split()) != " ".join(TABLE.split())
            or index is None
            or index["type"] != "index"
            or index["tbl_name"] != "inventory_items"
            or index["sql"] is not None
        ):
            raise ValueError("invalid_inventory_schema")
        audit = by_name.pop("inventory_audit", None)
        state = by_name.pop("inventory_audit_state", None)
        by_name.pop("sqlite_sequence", None)
        by_name.pop("sqlite_autoindex_inventory_audit_state_1", None)
        if (by_name or audit is None or state is None or
                " ".join(audit["sql"].split()) != " ".join(AUDIT.split()) or
                " ".join(state["sql"].split()) != " ".join(AUDIT_STATE.split())):
            raise ValueError("invalid_inventory_schema")
        indexes = connection.execute("PRAGMA index_list(inventory_items)").fetchall()
        columns = connection.execute(
            "PRAGMA index_info(sqlite_autoindex_inventory_items_1)"
        ).fetchall()
        if (
            [(row["name"], row["unique"], row["origin"], row["partial"]) for row in indexes]
            != [("sqlite_autoindex_inventory_items_1", 1, "pk", 0)]
            or [(row["seqno"], row["cid"], row["name"]) for row in columns]
            != [(0, 0, "id")]
        ):
            raise ValueError("invalid_inventory_index")
    except (ValueError, TypeError, sqlite3.Error):
        raise StartupError("inventory_storage_invalid") from None
