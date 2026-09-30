"""Actual F36 Flutter Client through normal Core TCP and durable F54."""

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from conftest import auth, login, ready, server as core_fixture
from support.installed_core_tcp import InstalledCoreTcp
from test_admin import activate, create as create_user, users


PASSWORD = "Synthetic new password 2026"


def _notification_root(app):
    scope = app.state.core.context
    return f"/api/v1/local-notifications/{scope.coreId}/{scope.homeId}"


def _register(client, actor, root, clock):
    response = client.post(
        root + "/subscriptions",
        headers=auth(actor),
        json={
            "schemaVersion": 1,
            "registrationId": uuid.uuid4().hex,
            "permission": "granted",
            "expiresAt": clock() + 3600,
        },
    )
    if response.status_code != 201:
        raise RuntimeError("notification_registration_failed:" + response.text)
    return response.json()["subscription"]


def _events(client, actor, root, subscription):
    response = client.get(
        root + f"/subscriptions/{subscription['ref']['id']}/events",
        headers=auth(actor),
        params={"expectedRevision": subscription["revision"]},
    )
    if response.status_code != 200:
        raise RuntimeError("notification_read_failed:" + response.text)
    return response.json()["events"]


def _counts(core):
    with core.db.connection() as connection:
        actions = connection.execute(
            "SELECT action,COUNT(*) AS count FROM fair_chore_events "
            "GROUP BY action ORDER BY action"
        ).fetchall()
        notifications = connection.execute(
            "SELECT COUNT(*) FROM local_notification_events"
        ).fetchone()[0]
        ciphertexts = connection.execute(
            "SELECT ciphertext FROM local_notification_events ORDER BY sequence"
        ).fetchall()
    return [(row["action"], row["count"]) for row in actions], notifications, ciphertexts


def main():
    with tempfile.TemporaryDirectory(prefix="larenor-f36-client-") as root:
        root = Path(root)
        client_state = root / "client-proof.json"
        runner_state = root / "runner-proof.json"
        for phase in ("create", "restart"):
            generator = core_fixture.__wrapped__(root)
            app, client, settings, clock = next(generator)
            try:
                notification_root = _notification_root(app)
                if phase == "create":
                    admin = ready((app, client, settings, clock))
                    clock.now += 1
                    member_user = create_user(client, admin)
                    member = activate(client, "member")
                    clock.now -= 1
                    proof = {
                        "admin": admin,
                        "member": member,
                        "memberId": member_user["id"],
                        "adminSubscription": _register(
                            client, admin, notification_root, clock
                        ),
                        "memberSubscription": _register(
                            client, member, notification_root, clock
                        ),
                    }
                    runner_state.write_text(json.dumps(proof))
                else:
                    proof = json.loads(runner_state.read_text())
                    admin = login(client, "admin", PASSWORD).json()
                    member_revision = next(
                        value["revision"]
                        for value in users(client, admin)
                        if value["id"] == proof["memberId"]
                    )
                    disabled = client.patch(
                        f"/api/v1/admin/users/{proof['memberId']}",
                        headers=auth(admin),
                        json={
                            "expectedRevision": member_revision,
                            "disabled": True,
                        },
                    )
                    if disabled.status_code != 200:
                        raise RuntimeError("member_departure_failed:" + disabled.text)

                with InstalledCoreTcp(app) as tcp:
                    result = subprocess.run(
                        [
                            "flutter",
                            "test",
                            "--no-pub",
                            "test/features/fair_chores/"
                            "fair_chore_normal_core_test.dart",
                        ],
                        env={
                            **os.environ,
                            "LARENOR_CHORE_CORE_URL": f"http://127.0.0.1:{tcp.port}",
                            "LARENOR_CHORE_PHASE": phase,
                            "LARENOR_CHORE_STATE_FILE": str(client_state),
                        },
                        cwd=Path(__file__).resolve().parents[3],
                        timeout=120,
                        check=False,
                    )
                    if result.returncode:
                        return result.returncode

                proof = json.loads(runner_state.read_text())
                actions, notification_count, ciphertexts = _counts(app.state.core)
                if phase == "create":
                    expected_actions = [("completed", 1), ("created", 1), ("deferred", 1)]
                    events = _events(
                        client,
                        proof["member"],
                        notification_root,
                        proof["memberSubscription"],
                    )
                else:
                    expected_actions = [
                        ("completed", 2),
                        ("created", 1),
                        ("deferred", 1),
                        ("skipped", 1),
                    ]
                    events = _events(
                        client,
                        proof["admin"],
                        notification_root,
                        proof["adminSubscription"],
                    )
                expected_notifications = 1 if phase == "create" else 2
                if actions != expected_actions:
                    raise RuntimeError("chore_effect_count:" + repr(actions))
                if notification_count != expected_notifications or len(events) != 1:
                    raise RuntimeError("notification_effect_count")
                if any(
                    event["category"] != "fair_chore"
                    or event["sensitivity"] != "private"
                    or event["target"] != "/chores"
                    for event in events
                ):
                    raise RuntimeError("notification_contract_changed")
                if any(
                    b"Household chore" in row["ciphertext"]
                    or b"recurring household" in row["ciphertext"]
                    for row in ciphertexts
                ):
                    raise RuntimeError("notification_plaintext_at_rest")
                app.state.core.local_notifications.validate_storage()
                for task in app.state.core.fair_chores.store.list(
                    app.state.core.auth.authenticate(admin["accessToken"]),
                    core_id=app.state.core.context.coreId,
                    home_id=app.state.core.context.homeId,
                    current_members=app.state.core.fair_chores._members(
                        app.state.core.auth.authenticate(admin["accessToken"])
                    )[0],
                ):
                    with app.state.core.db.connection() as connection:
                        app.state.core.fair_chores.store._assert_current(
                            connection, task
                        )
            finally:
                generator.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
