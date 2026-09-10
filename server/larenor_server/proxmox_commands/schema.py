import hashlib
import hmac


MAX_RECEIPTS = 256


def state_tag(key: bytes, count: int) -> str:
    return hmac.new(key, f"larenor-proxmox-power-state-v1:{count}".encode("ascii"), hashlib.sha256).hexdigest()


def migrate(connection, key: bytes) -> None:
    connection.execute("""CREATE TABLE IF NOT EXISTS proxmox_power_receipts (
        request_id TEXT PRIMARY KEY,
        resource_id TEXT NOT NULL,
        user_id TEXT NOT NULL,
        nonce BLOB NOT NULL,
        ciphertext BLOB NOT NULL,
        updated_at REAL NOT NULL
    )""")
    connection.execute("""CREATE TABLE IF NOT EXISTS proxmox_power_state (
        singleton INTEGER PRIMARY KEY CHECK(singleton=1),
        receipt_count INTEGER NOT NULL,
        authentication_tag TEXT NOT NULL
    )""")
    row = connection.execute("SELECT receipt_count FROM proxmox_power_state WHERE singleton=1").fetchone()
    if row is None:
        count = connection.execute("SELECT COUNT(*) FROM proxmox_power_receipts").fetchone()[0]
        connection.execute("INSERT INTO proxmox_power_state VALUES(1,?,?)", (count, state_tag(key, count)))
