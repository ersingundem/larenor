import sqlite3

from ..errors import StartupError


MAX_ITEMS = 1000
TABLE = """CREATE TABLE inventory_items (
    id TEXT PRIMARY KEY,
    revision INTEGER NOT NULL CHECK(revision > 0),
    created_by TEXT NOT NULL,
    nonce BLOB NOT NULL,
    ciphertext BLOB NOT NULL)"""


def migrate_inventory(connection):
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
            connection.execute("INSERT INTO metadata VALUES('inventory_schema','1')")
            return
        table = by_name.pop("inventory_items", None)
        index = by_name.pop("sqlite_autoindex_inventory_items_1", None)
        if (
            marker["value"] != "1"
            or by_name
            or table is None
            or table["type"] != "table"
            or " ".join(table["sql"].split()) != " ".join(TABLE.split())
            or index is None
            or index["type"] != "index"
            or index["tbl_name"] != "inventory_items"
            or index["sql"] is not None
        ):
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
