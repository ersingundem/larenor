"""Actual F54 Flutter Client through normal Core TCP and durable restart."""

import os
from pathlib import Path
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from conftest import auth, login, ready, server as core_fixture
from support.installed_core_tcp import InstalledCoreTcp
from support.named_flutter_acceptance import run_named_flutter


PASSWORD = "Synthetic new password 2026"
TEST_FILE = (
    "test/features/local_notifications/local_notification_normal_core_test.dart"
)
TEST_NAME = (
    "real Client persists the subscription and deduplicates a safe tap after restart"
)


def _root(app):
    scope = app.state.core.context
    return f"/api/v1/local-notifications/{scope.coreId}/{scope.homeId}"


def _event(recipient, *, key, public):
    return {
        "schemaVersion": 1,
        "recipientUserId": recipient,
        "idempotencyKey": key,
        "category": "security",
        "sensitivity": "public" if public else "private",
        "title": "Door ready" if public else "Front door",
        "body": "Open the dashboard" if public else "Motion was detected",
        "target": "/today" if public else "/system/security",
    }


def _publish(client, admin, root, body):
    response = client.post(root + "/events", headers=auth(admin), json=body)
    if response.status_code != 201:
        raise RuntimeError("notification_publish_failed")
    return response.json()["notification"]


def main():
    with tempfile.TemporaryDirectory(prefix="larenor-f54-client-") as directory:
        directory = Path(directory)
        store = directory / "subscription.json"
        private_sequence = None
        for phase in ("create", "restart"):
            generator = core_fixture.__wrapped__(directory)
            app, client, settings, clock = next(generator)
            try:
                admin = ready((app, client, settings, clock)) if phase == "create" else login(
                    client, "admin", PASSWORD
                ).json()
                root = _root(app)
                private = _publish(
                    client,
                    admin,
                    root,
                    _event(
                        admin["user"]["id"],
                        key="f54-private-restart-proof",
                        public=False,
                    ),
                )
                if private_sequence is None:
                    private_sequence = private["sequence"]
                elif private["sequence"] != private_sequence:
                    raise RuntimeError("notification_replay_changed")
                if phase == "restart":
                    _publish(
                        client,
                        admin,
                        root,
                        _event(
                            admin["user"]["id"],
                            key="f54-public-safe-route-proof",
                            public=True,
                        ),
                    )

                with InstalledCoreTcp(app) as tcp:
                    counts = run_named_flutter(
                        test_file=TEST_FILE,
                        test_name=TEST_NAME,
                        env={
                            **os.environ,
                            "LARENOR_F54_CORE_URL": f"http://127.0.0.1:{tcp.port}",
                            "LARENOR_F54_PHASE": phase,
                            "LARENOR_F54_STORE_FILE": str(store),
                        },
                        cwd=Path(__file__).resolve().parents[3],
                        log_path=directory / f"f54-{phase}.machine.jsonl",
                        timeout_seconds=120,
                    )
                    print(
                        f"F54 {phase}: named1 passed1 failures0 errors0 skipped0"
                    )
                    if counts["passed"] != 1:
                        return 1

                with app.state.core.db.connection() as connection:
                    rows = connection.execute(
                        "SELECT idempotency_key,COUNT(*) AS count FROM "
                        "local_notification_events GROUP BY idempotency_key "
                        "ORDER BY idempotency_key"
                    ).fetchall()
                    expected = 1 if phase == "create" else 2
                    acknowledged = connection.execute(
                        "SELECT COUNT(*) FROM local_notification_acks "
                        "WHERE acknowledged_at IS NOT NULL"
                    ).fetchone()[0]
                if len(rows) != expected or any(row["count"] != 1 for row in rows):
                    raise RuntimeError("notification_duplicate_effect")
                if acknowledged != expected:
                    raise RuntimeError("notification_acknowledgement_count")
                app.state.core.local_notifications.validate_storage()
            finally:
                generator.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
