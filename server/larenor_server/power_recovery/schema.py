from ..errors import StartupError


_POLICY_COLUMNS = (
    ("id", "INTEGER", 0, None, 1),
    ("revision", "INTEGER", 1, None, 0),
    ("source_id", "TEXT", 1, None, 0),
    ("critical_runtime_seconds", "INTEGER", 1, None, 0),
    ("restore_stable_seconds", "INTEGER", 1, None, 0),
    ("targets_json", "TEXT", 1, None, 0),
    ("token_nonce", "BLOB", 1, None, 0),
    ("token_ciphertext", "BLOB", 1, None, 0),
    ("configured_at", "INTEGER", 1, None, 0),
)


def migrate_power_recovery(connection):
    marker = connection.execute(
        "SELECT value FROM metadata WHERE key='power_recovery_schema'"
    ).fetchone()
    exists = connection.execute(
        "SELECT 1 FROM sqlite_master WHERE type='table' AND name='power_recovery_policy'"
    ).fetchone()
    if marker is None:
        if exists:
            raise StartupError("power_recovery_schema_unsupported")
        statements = (
            """CREATE TABLE power_recovery_policy (
                id INTEGER PRIMARY KEY CHECK(id=1),
                revision INTEGER NOT NULL CHECK(revision>0),
                source_id TEXT NOT NULL CHECK(length(source_id) BETWEEN 1 AND 64),
                critical_runtime_seconds INTEGER NOT NULL CHECK(critical_runtime_seconds BETWEEN 60 AND 3600),
                restore_stable_seconds INTEGER NOT NULL CHECK(restore_stable_seconds BETWEEN 30 AND 3600),
                targets_json TEXT NOT NULL CHECK(length(targets_json) BETWEEN 2 AND 65536),
                token_nonce BLOB NOT NULL CHECK(length(token_nonce)=12),
                token_ciphertext BLOB NOT NULL CHECK(length(token_ciphertext) BETWEEN 48 AND 1024),
                configured_at INTEGER NOT NULL
            )""",
            """CREATE TABLE power_recovery_state (
                id INTEGER PRIMARY KEY CHECK(id=1),
                source_state TEXT NOT NULL CHECK(source_state IN ('online','onBattery','lowBattery')),
                gate_state TEXT NOT NULL CHECK(gate_state IN ('open','held')),
                last_sequence INTEGER NOT NULL CHECK(last_sequence>=0),
                last_observed_at INTEGER,
                online_since INTEGER,
                active_run_id TEXT
            )""",
            "INSERT INTO power_recovery_state VALUES(1,'online','open',0,NULL,NULL,NULL)",
            """CREATE TABLE power_recovery_events (
                event_id TEXT PRIMARY KEY CHECK(length(event_id)=32),
                source_revision INTEGER NOT NULL CHECK(source_revision>0),
                sequence INTEGER NOT NULL UNIQUE CHECK(sequence>0),
                state TEXT NOT NULL CHECK(state IN ('online','onBattery','lowBattery')),
                charge_percent INTEGER NOT NULL CHECK(charge_percent BETWEEN 0 AND 100),
                runtime_seconds INTEGER NOT NULL CHECK(runtime_seconds BETWEEN 0 AND 86400),
                observed_at INTEGER NOT NULL,
                received_at INTEGER NOT NULL
            )""",
            """CREATE TABLE power_recovery_runs (
                run_id TEXT PRIMARY KEY CHECK(length(run_id)=32),
                policy_revision INTEGER NOT NULL CHECK(policy_revision>0),
                trigger_event_id TEXT NOT NULL REFERENCES power_recovery_events(event_id),
                state TEXT NOT NULL CHECK(state IN ('draining','shuttingDown','protected','restoring','completed','failed')),
                created_at INTEGER NOT NULL,
                updated_at INTEGER NOT NULL,
                restore_eligible_at INTEGER,
                failure_code TEXT CHECK(failure_code IS NULL OR failure_code IN ('active_work_timeout','checkpoint_failed','effect_failed'))
            )""",
            """CREATE TABLE power_recovery_steps (
                step_id TEXT PRIMARY KEY CHECK(length(step_id)=32),
                run_id TEXT NOT NULL REFERENCES power_recovery_runs(run_id),
                sequence INTEGER NOT NULL CHECK(sequence>0),
                action TEXT NOT NULL CHECK(action IN ('holdNewWork','drainActiveWork','checkpointDatabase','shutdownTarget','startTarget','releaseNewWork')),
                target_id TEXT,
                target_kind TEXT CHECK(target_kind IS NULL OR target_kind IN ('service','proxmoxGuest','networkDevice','coreHost')),
                state TEXT NOT NULL CHECK(state IN ('queued','executing','succeeded','failed','skipped')),
                result_code TEXT NOT NULL CHECK(result_code IN ('pending','completed','no_active_work','active_work_timeout','checkpoint_failed','effect_failed','restore_disabled')),
                created_at INTEGER NOT NULL,
                updated_at INTEGER NOT NULL,
                UNIQUE(run_id,sequence)
            )""",
            "CREATE INDEX power_recovery_runs_recent ON power_recovery_runs(created_at DESC)",
            "INSERT INTO metadata(key,value) VALUES('power_recovery_schema','1')",
        )
        for statement in statements:
            connection.execute(statement)
    elif marker["value"] != "1" or not exists:
        raise StartupError("power_recovery_schema_unsupported")
    columns = tuple(
        tuple(row)
        for row in connection.execute(
            'SELECT name,type,"notnull",dflt_value,pk FROM pragma_table_info("power_recovery_policy")'
        )
    )
    if columns != _POLICY_COLUMNS:
        raise StartupError("power_recovery_schema_unsupported")
