import json

import pytest

from fastapi.testclient import TestClient

from conftest import auth, ready
from larenor_server.app import create_app
from larenor_server.workshop import schema as workshop_schema
from test_f59_workshop_printer_core import (
    octoprint,
    preview_body,
    register,
    root,
)


class _AppliedProvider:
    def __init__(self, clock):
        self.clock = clock
        self.calls: list[str] = []

    def capability(self, _actor, _binding, _printer_id):
        return {
            "schemaVersion": 1,
            "providerRevision": 3,
            "supportedActions": ["pause", "cancel"],
            "observedAt": self.clock.now,
        }

    def execute(self, _actor, _binding, command):
        self.calls.append(command["commandId"])
        return {
            "schemaVersion": 1,
            "commandId": command["commandId"],
            "printerId": command["printerId"],
            "action": command["action"],
            "providerRevision": command["providerRevision"],
            "jobRevision": command["expectedJobRevision"] + 1,
            "jobState": "paused",
            "connectivity": "online",
            "observedAt": self.clock.now,
        }


def _confirm(client, admin, app, printer, *, request_key):
    endpoint = root(app) + f"/printers/{printer['ref']['id']}/previews"
    pending = client.post(
        endpoint,
        headers=auth(admin),
        json=preview_body(printer, request_key=request_key),
    )
    assert pending.status_code == 201, pending.text
    preview = pending.json()["preview"]
    return client.post(
        endpoint + f"/{preview['id']}/confirm",
        headers=auth(admin),
        json={
            "schemaVersion": 1,
            "confirmationToken": preview["confirmationToken"],
        },
    )


def _seed_history(
    app,
    *,
    count,
    created_at,
    offset=0,
    status="applied",
):
    service = app.state.core.workshop
    seeded = []
    with app.state.core.db.transaction() as connection:
        template_intent = dict(
            connection.execute(
                "SELECT * FROM workshop_intents ORDER BY sequence LIMIT 1"
            ).fetchone()
        )
        template_effect = dict(
            connection.execute(
                "SELECT * FROM workshop_effects ORDER BY intent_id LIMIT 1"
            ).fetchone()
        )
        for index in range(count):
            ordinal = offset + index + 1
            intent_id = f"{ordinal:032x}"
            command_id = f"{ordinal + 100_000:032x}"
            connection.execute(
                "INSERT INTO workshop_intents "
                "(id,printer_id,actor_id,request_key,action,printer_revision,"
                "service_revision,job_revision,material_revision,safety_revision,"
                "state,effect,created_at,envelope_tag) VALUES(?,?,?,?,?,?,?,?,?,?,"
                "'recorded','notDispatched',?,'')",
                (
                    intent_id,
                    template_intent["printer_id"],
                    template_intent["actor_id"],
                    f"retention-seed-{ordinal:08d}",
                    template_intent["action"],
                    template_intent["printer_revision"],
                    template_intent["service_revision"],
                    template_intent["job_revision"],
                    template_intent["material_revision"],
                    template_intent["safety_revision"],
                    created_at,
                ),
            )
            intent = connection.execute(
                "SELECT * FROM workshop_intents WHERE id=?", (intent_id,)
            ).fetchone()
            connection.execute(
                "UPDATE workshop_intents SET envelope_tag=? WHERE id=?",
                (service._intent_tag(intent), intent_id),
            )
            readback = json.loads(template_effect["readback_json"])
            readback["commandId"] = command_id
            encoded = (
                json.dumps(
                    readback,
                    sort_keys=True,
                    separators=(",", ":"),
                    allow_nan=False,
                )
                if status == "applied"
                else None
            )
            effect = {
                **template_effect,
                "intent_id": intent_id,
                "command_id": command_id,
                "status": status,
                "code": "applied" if status == "applied" else "worker_ack_unknown",
                "readback_json": encoded,
                "created_at": created_at,
            }
            effect["envelope_tag"] = service._effect_tag(effect)
            connection.execute(
                "INSERT INTO workshop_effects VALUES(?,?,?,?,?,?,?,?)",
                tuple(
                    effect[name]
                    for name in (
                        "intent_id",
                        "command_id",
                        "status",
                        "code",
                        "provider_revision",
                        "readback_json",
                        "created_at",
                        "envelope_tag",
                    )
                ),
            )
            seeded.append(intent_id)
    return seeded


def _setup(server):
    app, client, settings, clock = server
    admin = ready(server)
    service = octoprint(client, admin, app)
    printer = register(client, admin, app, clock, service)
    provider = _AppliedProvider(clock)
    app.state.core.workshop.provider = provider
    initial = _confirm(
        client,
        admin,
        app,
        printer,
        request_key="retention-current-0001",
    )
    assert initial.status_code == 201, initial.text
    assert len(provider.calls) == 1
    return app, client, settings, clock, admin, printer, provider, initial.json()


def test_default_capacity_recovers_after_restart_without_replaying_provider(server):
    app, _client, settings, clock, admin, printer, provider, _initial = _setup(
        server
    )

    _seed_history(
        app,
        count=workshop_schema.MAX_INTENTS - 1,
        created_at=clock.now - 86_401,
    )
    current_history_id = f"{workshop_schema.MAX_INTENTS - 1:032x}"
    with app.state.core.db.connection() as connection:
        assert connection.execute(
            "SELECT COUNT(*) FROM workshop_intents"
        ).fetchone()[0] == workshop_schema.MAX_INTENTS

    restarted_provider = _AppliedProvider(clock)
    with TestClient(create_app(settings)) as restarted:
        restarted.app.state.core.workshop.provider = restarted_provider
        response = _confirm(
            restarted,
            admin,
            restarted.app,
            printer,
            request_key="retention-next-0002",
        )
        assert response.status_code == 201, response.text
        assert len(restarted_provider.calls) == 1
        with restarted.app.state.core.db.connection() as connection:
            assert connection.execute(
                "SELECT COUNT(*) FROM workshop_intents"
            ).fetchone()[0] == 3
            assert connection.execute(
                "SELECT COUNT(*) FROM workshop_effects"
            ).fetchone()[0] == 3
            assert connection.execute(
                "SELECT COUNT(*) FROM workshop_intents WHERE id=?",
                (current_history_id,),
            ).fetchone()[0] == 1


def test_retention_keeps_inclusive_replay_boundary_and_exact_recent_replay(
    server, monkeypatch
):
    app, client, _settings, clock, admin, printer, provider, initial = _setup(server)
    old_id = _seed_history(app, count=1, created_at=clock.now - 86_401)[0]
    boundary_id = _seed_history(
        app,
        count=1,
        offset=10,
        created_at=clock.now - 86_400,
    )[0]
    current_id = _seed_history(
        app,
        count=1,
        offset=20,
        created_at=clock.now - 86_401,
    )[0]
    monkeypatch.setattr(workshop_schema, "MAX_INTENTS", 4)

    created = _confirm(
        client,
        admin,
        app,
        printer,
        request_key="retention-after-boundary-0002",
    )
    assert created.status_code == 201, created.text
    assert len(provider.calls) == 2
    replay = _confirm(
        client,
        admin,
        app,
        printer,
        request_key="retention-current-0001",
    )
    assert replay.status_code == 201
    assert replay.json() == initial
    assert len(provider.calls) == 2
    with app.state.core.db.connection() as connection:
        retained = {
            row[0]
            for row in connection.execute("SELECT id FROM workshop_intents")
        }
        assert old_id not in retained
        assert boundary_id in retained
        assert current_id in retained
        assert len(retained) == 4


def test_unknown_effect_is_never_pruned_or_redispatched(server, monkeypatch):
    app, client, _settings, clock, admin, printer, provider, _initial = _setup(server)
    unknown_id = _seed_history(
        app,
        count=1,
        created_at=clock.now - 10 * 86_400,
        status="unknown",
    )[0]
    monkeypatch.setattr(workshop_schema, "MAX_INTENTS", 2)

    blocked = _confirm(
        client,
        admin,
        app,
        printer,
        request_key="retention-unknown-blocked-0002",
    )
    assert blocked.status_code == 409, blocked.text
    assert blocked.json()["error"]["code"] == "workshop_limit_reached"
    assert len(provider.calls) == 1
    with app.state.core.db.connection() as connection:
        assert connection.execute(
            "SELECT status FROM workshop_effects WHERE intent_id=?", (unknown_id,)
        ).fetchone()[0] == "unknown"
        assert connection.execute(
            "SELECT COUNT(*) FROM workshop_intents"
        ).fetchone()[0] == 2


@pytest.mark.parametrize("target", ["intent", "effect"])
def test_tampered_history_fails_closed_before_any_deletion(
    server, monkeypatch, target
):
    app, client, _settings, clock, admin, printer, provider, _initial = _setup(server)
    old_id = _seed_history(app, count=1, created_at=clock.now - 86_401)[0]
    monkeypatch.setattr(workshop_schema, "MAX_INTENTS", 2)
    with app.state.core.db.transaction() as connection:
        if target == "intent":
            connection.execute(
                "UPDATE workshop_intents SET request_key=? WHERE id=?",
                ("tampered-request-key-0001", old_id),
            )
        else:
            connection.execute(
                "UPDATE workshop_effects SET created_at=created_at+1 "
                "WHERE intent_id=?",
                (old_id,),
            )

    rejected = _confirm(
        client,
        admin,
        app,
        printer,
        request_key=f"retention-tamper-{target}-0002",
    )
    assert rejected.status_code == 503, rejected.text
    assert rejected.json()["error"]["code"] == "workshop_storage_unavailable"
    assert len(provider.calls) == 1
    with app.state.core.db.connection() as connection:
        assert connection.execute(
            "SELECT COUNT(*) FROM workshop_intents"
        ).fetchone()[0] == 2
        assert connection.execute(
            "SELECT COUNT(*) FROM workshop_effects"
        ).fetchone()[0] == 2


def test_applied_effect_with_mismatched_child_readback_fails_closed(
    server, monkeypatch
):
    app, client, _settings, clock, admin, printer, provider, _initial = _setup(server)
    old_id = _seed_history(app, count=1, created_at=clock.now - 86_401)[0]
    monkeypatch.setattr(workshop_schema, "MAX_INTENTS", 2)
    with app.state.core.db.transaction() as connection:
        row = dict(
            connection.execute(
                "SELECT * FROM workshop_effects WHERE intent_id=?", (old_id,)
            ).fetchone()
        )
        readback = json.loads(row["readback_json"])
        readback["printerId"] = "f" * 32
        row["readback_json"] = json.dumps(
            readback, sort_keys=True, separators=(",", ":"), allow_nan=False
        )
        row["envelope_tag"] = app.state.core.workshop._effect_tag(row)
        connection.execute(
            "UPDATE workshop_effects SET readback_json=?,envelope_tag=? "
            "WHERE intent_id=?",
            (row["readback_json"], row["envelope_tag"], old_id),
        )

    rejected = _confirm(
        client,
        admin,
        app,
        printer,
        request_key="retention-mismatched-child-0002",
    )
    assert rejected.status_code == 503, rejected.text
    assert len(provider.calls) == 1
    with app.state.core.db.connection() as connection:
        assert connection.execute(
            "SELECT COUNT(*) FROM workshop_intents"
        ).fetchone()[0] == 2


def test_delete_failure_rolls_back_the_entire_compaction(server, monkeypatch):
    app, client, _settings, clock, admin, printer, provider, _initial = _setup(server)
    old_id = _seed_history(
        app, count=2, created_at=clock.now - 86_401
    )[0]
    monkeypatch.setattr(workshop_schema, "MAX_INTENTS", 3)
    with app.state.core.db.transaction() as connection:
        connection.execute(
            "CREATE TRIGGER workshop_retention_abort BEFORE DELETE ON "
            "workshop_intents WHEN OLD.id='{}' BEGIN SELECT RAISE(ABORT, "
            "'retention_abort'); END".format(old_id)
        )

    rejected = _confirm(
        client,
        admin,
        app,
        printer,
        request_key="retention-rollback-0002",
    )
    assert rejected.status_code == 503, rejected.text
    assert len(provider.calls) == 1
    with app.state.core.db.connection() as connection:
        assert connection.execute(
            "SELECT COUNT(*) FROM workshop_intents"
        ).fetchone()[0] == 3
        assert connection.execute(
            "SELECT COUNT(*) FROM workshop_effects"
        ).fetchone()[0] == 3
