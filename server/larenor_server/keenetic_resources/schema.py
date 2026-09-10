"""Keyed encrypted binding inventory for central Keenetic telemetry."""
import hashlib
import hmac
import json

MAX_BINDINGS = 128
MAX_CIPHER = 2048
TABLES = {
    "keenetic_resource_bindings": """CREATE TABLE keenetic_resource_bindings (
        resource_id TEXT PRIMARY KEY, binding_id TEXT NOT NULL UNIQUE,
        revision INTEGER NOT NULL CHECK(revision > 0), nonce BLOB NOT NULL,
        ciphertext BLOB NOT NULL)""",
    "keenetic_resource_state": """CREATE TABLE keenetic_resource_state (
        singleton INTEGER PRIMARY KEY CHECK(singleton=1),
        authentication_tag TEXT NOT NULL)""",
}


def rows(c):
    bounds = c.execute("SELECT COUNT(*), COALESCE(SUM(CASE WHEN "
        "typeof(resource_id)='text' AND length(CAST(resource_id AS BLOB))=32 AND resource_id NOT GLOB '*[^0-9a-f]*' "
        "AND typeof(binding_id)='text' AND length(CAST(binding_id AS BLOB))=32 AND binding_id NOT GLOB '*[^0-9a-f]*' "
        "AND typeof(revision)='integer' AND revision>0 AND typeof(nonce)='blob' AND length(nonce)=12 "
        "AND typeof(ciphertext)='blob' AND length(ciphertext) BETWEEN 16 AND ? THEN 0 ELSE 1 END),0) "
        "FROM keenetic_resource_bindings", (MAX_CIPHER,)).fetchone()
    if bounds[0] > MAX_BINDINGS or bounds[1]:
        raise ValueError()
    return c.execute("SELECT * FROM keenetic_resource_bindings ORDER BY resource_id LIMIT ?",
                     (MAX_BINDINGS + 1,)).fetchall()


def tag(key, scope, values):
    payload = [scope.coreId, scope.homeId, [[r["resource_id"], r["binding_id"], r["revision"],
        hashlib.sha256(r["nonce"] + r["ciphertext"]).hexdigest()] for r in values]]
    return hmac.new(key, b"larenor-keenetic-resources-v1\0" + json.dumps(
        payload, separators=(",", ":")).encode(), hashlib.sha256).hexdigest()


def validate(c, key, scope):
    values = rows(c)
    state = c.execute("SELECT * FROM keenetic_resource_state LIMIT 2").fetchall()
    if (len(state) != 1 or state[0]["singleton"] != 1 or
            not hmac.compare_digest(state[0]["authentication_tag"], tag(key, scope, values))):
        raise ValueError()
    return values


def update(c, key, scope):
    c.execute("UPDATE keenetic_resource_state SET authentication_tag=? WHERE singleton=1",
              (tag(key, scope, rows(c)),))


def migrate(c, scope, key):
    marker = c.execute("SELECT value FROM metadata WHERE key='keenetic_resource_schema'").fetchone()
    actual = {r["name"]: r for r in c.execute("SELECT name,type,sql FROM sqlite_master "
        "WHERE name GLOB 'keenetic_resource_*' OR tbl_name IN "
        "('keenetic_resource_bindings','keenetic_resource_state')")}
    if marker is None:
        if actual:
            raise ValueError()
        for statement in TABLES.values():
            c.execute(statement)
        c.execute("INSERT INTO metadata VALUES('keenetic_resource_schema','1')")
        c.execute("INSERT INTO keenetic_resource_state VALUES(1,?)", (tag(key, scope, []),))
    else:
        if marker["value"] != "1":
            raise ValueError()
        # Include SQLite's two required autoindexes in the exact inventory.
        tables = {name: row for name, row in actual.items() if row["type"] == "table"}
        if set(tables) != set(TABLES) or any(" ".join(tables[n]["sql"].split()) != " ".join(sql.split())
                                            for n, sql in TABLES.items()):
            raise ValueError()
        validate(c, key, scope)
