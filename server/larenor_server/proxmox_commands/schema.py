import hashlib
import hmac


MAX_RECEIPTS = 256
MAX_JOURNAL_EVENTS = 2048
EMPTY_HEAD = "0" * 64


def state_tag(key: bytes, count: int) -> str:
    return hmac.new(key, f"larenor-proxmox-power-state-v1:{count}".encode("ascii"), hashlib.sha256).hexdigest()


def journal_state_tag(key: bytes, count: int, head_hash: str) -> str:
    return hmac.new(
        key, f"larenor-proxmox-journal-state-v1:{count}:{head_hash}".encode("ascii"), hashlib.sha256
    ).hexdigest()


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
    connection.execute("""CREATE TABLE IF NOT EXISTS proxmox_power_journal (
        sequence INTEGER PRIMARY KEY AUTOINCREMENT,
        resource_id TEXT NOT NULL,
        user_id TEXT NOT NULL,
        request_id TEXT NOT NULL,
        event_kind TEXT NOT NULL,
        action TEXT NOT NULL,
        state TEXT NOT NULL,
        result_code TEXT NOT NULL,
        user_revision INTEGER NOT NULL,
        resource_revision INTEGER NOT NULL,
        acl_revision INTEGER NOT NULL,
        binding_revision INTEGER NOT NULL,
        service_revision INTEGER NOT NULL,
        status_revision INTEGER NOT NULL,
        operation_ref TEXT,
        emitted_at REAL NOT NULL,
        previous_hash TEXT NOT NULL,
        entry_hash TEXT NOT NULL
    )""")
    connection.execute("""CREATE TABLE IF NOT EXISTS proxmox_power_journal_state (
        singleton INTEGER PRIMARY KEY CHECK(singleton=1),
        event_count INTEGER NOT NULL,
        head_hash TEXT NOT NULL,
        authentication_tag TEXT NOT NULL
    )""")
    journal = connection.execute("SELECT event_count FROM proxmox_power_journal_state WHERE singleton=1").fetchone()
    if journal is None:
        count = connection.execute("SELECT COUNT(*) FROM proxmox_power_journal").fetchone()[0]
        if count:
            raise ValueError("journal_state_missing")
        connection.execute(
            "INSERT INTO proxmox_power_journal_state VALUES(1,?,?,?)",
            (0, EMPTY_HEAD, journal_state_tag(key, 0, EMPTY_HEAD)),
        )
