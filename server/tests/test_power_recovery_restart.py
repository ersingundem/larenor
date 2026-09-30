import json
from dataclasses import replace

from cryptography.hazmat.primitives.ciphers.aead import AESGCM

from larenor_server.config import Settings
from larenor_server.database import Database
from larenor_server.power_recovery.models import PowerEffectReceipt
from larenor_server.power_recovery.schema import migrate_power_recovery
from larenor_server.power_recovery.service import PowerRecoveryService


RUN = "1" * 32
EVENT = "2" * 32
STEP = "3" * 32
TARGET = "4" * 32
KEY = b"power-recovery-restart-test-key!"
NOW = 1_788_609_600


class Executor:
    def __init__(self, receipt=None):
        self.receipt = receipt
        self.executed = []
        self.reconciled = []

    def execute(self, request):
        self.executed.append(request)
        raise AssertionError("restart must not replay an irreversible effect")

    def reconcile(self, request):
        self.reconciled.append(request)
        return self.receipt


def database(tmp_path, *, action="shutdownTarget", state="executing"):
    db = Database(tmp_path / "power.sqlite3")
    db.create_schema()
    with db.transaction() as connection:
        migrate_power_recovery(connection)
        nonce = b"r" * 12
        ciphertext = AESGCM(KEY).encrypt(
            nonce,
            b"t" * 32,
            b"larenor-power-recovery-token-v1:1",
        )
        targets = json.dumps(
            [{
                "targetId": TARGET,
                "label": "Synthetic guest",
                "kind": "proxmoxGuest",
                "shutdownOrder": 1,
                "startOnRestore": True,
                "timeoutSeconds": 30,
            }],
            separators=(",", ":"),
            sort_keys=True,
        )
        connection.execute(
            "INSERT INTO power_recovery_policy VALUES(1,1,'ups',60,30,?,?,?,?)",
            (targets, nonce, ciphertext, NOW),
        )
        connection.execute(
            "INSERT INTO power_recovery_events VALUES(?,?,?,?,?,?,?,?)",
            (EVENT, 1, 1, "lowBattery", 10, 30, NOW, NOW),
        )
        connection.execute(
            "INSERT INTO power_recovery_runs VALUES(?,?,?,?,?,?,NULL,NULL)",
            (RUN, 1, EVENT, "shuttingDown", NOW, NOW),
        )
        target = action in {"shutdownTarget", "startTarget"}
        connection.execute(
            "INSERT INTO power_recovery_steps VALUES(?,?,?,?,?,?,?,?,?,?)",
            (
                STEP,
                RUN,
                1,
                action,
                TARGET if target else None,
                "proxmoxGuest" if target else None,
                state,
                "pending",
                NOW,
                NOW,
            ),
        )
        connection.execute(
            "UPDATE power_recovery_state SET source_state='lowBattery',"
            "gate_state='held',last_sequence=1,last_observed_at=?,active_run_id=? "
            "WHERE id=1",
            (NOW, RUN),
        )
    settings = Settings(tmp_path, tmp_path / "vault.key", clock=lambda: NOW + 1)
    return db, settings


def rows(db):
    with db.connection() as connection:
        step = connection.execute(
            "SELECT state,result_code FROM power_recovery_steps WHERE step_id=?",
            (STEP,),
        ).fetchone()
        run = connection.execute(
            "SELECT state,failure_code FROM power_recovery_runs WHERE run_id=?",
            (RUN,),
        ).fetchone()
        return dict(step), dict(run)


def test_restart_marks_unproven_target_effect_uncertain_without_replay(tmp_path):
    db, settings = database(tmp_path)
    executor = Executor()

    PowerRecoveryService(db, object(), settings, KEY, executor=executor)

    assert executor.executed == []
    assert len(executor.reconciled) == 1
    request = executor.reconciled[0]
    assert (request.runId, request.stepId, request.target.targetId) == (
        RUN,
        STEP,
        TARGET,
    )
    assert rows(db) == (
        {"state": "uncertain", "result_code": "reconciliation_required"},
        {"state": "failed", "failure_code": "effect_failed"},
    )


def test_restart_accepts_only_exact_read_only_terminal_evidence(tmp_path):
    db, settings = database(tmp_path)
    executor = Executor(PowerEffectReceipt(
        contractVersion=1,
        runId=RUN,
        stepId=STEP,
        targetId=TARGET,
        action="shutdown",
        status="completed",
        observedState="stopped",
        completedAt=NOW + 1,
    ))

    PowerRecoveryService(db, object(), settings, KEY, executor=executor)

    assert executor.executed == []
    assert len(executor.reconciled) == 1
    assert rows(db) == (
        {"state": "succeeded", "result_code": "completed"},
        {"state": "shuttingDown", "failure_code": None},
    )


def test_restart_rejects_terminal_evidence_predating_the_effect(tmp_path):
    db, settings = database(tmp_path)
    executor = Executor(PowerEffectReceipt(
        contractVersion=1,
        runId=RUN,
        stepId=STEP,
        targetId=TARGET,
        action="shutdown",
        status="completed",
        observedState="stopped",
        completedAt=NOW - 1,
    ))

    PowerRecoveryService(db, object(), settings, KEY, executor=executor)

    assert executor.executed == []
    assert rows(db) == (
        {"state": "uncertain", "result_code": "reconciliation_required"},
        {"state": "failed", "failure_code": "effect_failed"},
    )


def test_restart_requeues_local_checkpoint_without_external_reconcile(tmp_path):
    db, settings = database(tmp_path, action="checkpointDatabase")
    executor = Executor()

    PowerRecoveryService(db, object(), settings, KEY, executor=executor)

    assert executor.executed == []
    assert executor.reconciled == []
    assert rows(db) == (
        {"state": "queued", "result_code": "pending"},
        {"state": "shuttingDown", "failure_code": None},
    )


def test_restart_keeps_original_dispatch_deadline_and_rejects_late_receipt(tmp_path):
    db, settings = database(tmp_path)
    settings = replace(settings, clock=lambda: NOW + 100)
    executor = Executor(PowerEffectReceipt(
        contractVersion=1, runId=RUN, stepId=STEP, targetId=TARGET,
        action="shutdown", status="completed", observedState="stopped",
        completedAt=NOW + 31,
    ))

    PowerRecoveryService(db, object(), settings, KEY, executor=executor)

    assert executor.executed == []
    assert executor.reconciled[0].deadlineAt == NOW + 30
    assert rows(db)[0] == {
        "state": "uncertain", "result_code": "reconciliation_required",
    }


def test_v1_schema_migration_preserves_steps_and_adds_uncertain_state(tmp_path):
    db, _settings = database(tmp_path)
    with db.transaction() as connection:
        connection.execute(
            "UPDATE metadata SET value='1' WHERE key='power_recovery_schema'"
        )
        migrate_power_recovery(connection)
        marker = connection.execute(
            "SELECT value FROM metadata WHERE key='power_recovery_schema'"
        ).fetchone()["value"]
        connection.execute(
            """UPDATE power_recovery_steps
                SET state='uncertain',result_code='reconciliation_required'
                WHERE step_id=?""",
            (STEP,),
        )

    assert marker == "2"
    assert rows(db)[0] == {
        "state": "uncertain",
        "result_code": "reconciliation_required",
    }


def test_lost_live_effect_ack_reconciles_read_only_and_never_becomes_retryable(
    tmp_path,
):
    db, settings = database(tmp_path, state="queued")
    executor = Executor()
    service = PowerRecoveryService(db, object(), settings, KEY, executor=executor)

    assert service.tick() is False

    assert len(executor.executed) == 1
    assert len(executor.reconciled) == 1
    assert rows(db) == (
        {"state": "uncertain", "result_code": "reconciliation_required"},
        {"state": "failed", "failure_code": "effect_failed"},
    )
