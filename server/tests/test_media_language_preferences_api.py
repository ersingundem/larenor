import json

import pytest
from fastapi.testclient import TestClient

from conftest import auth, login, ready
from larenor_server.app import create_app
from larenor_server.errors import StartupError
from test_admin import activate, create


def root(app):
    context = app.state.core.context
    return (
        f"/api/v1/media/language-preferences/"
        f"{context.coreId}/{context.homeId}"
    )


def account_revision(client, pair):
    users = client.get("/api/v1/admin/users", headers=auth(pair)).json()["users"]
    return next(value["revision"] for value in users if value["id"] == pair["user"]["id"])


def body(account, *, request="a" * 32, revision=0, audio="tr-tr", subtitle="off"):
    return {
        "schemaVersion": 1,
        "requestId": request,
        "expectedAccountRevision": account,
        "expectedRevision": revision,
        "audioLanguage": audio,
        "subtitleLanguage": subtitle,
    }


def test_versioned_account_home_contract_replays_exact_put_and_is_openapi_typed(server):
    app, client, settings, _clock = server
    admin = ready(server)
    endpoint = root(app)
    revision = account_revision(client, admin)

    empty = client.get(endpoint, headers=auth(admin))
    assert empty.status_code == 200
    assert empty.json()["preference"] is None
    assert empty.json()["authority"]["preferenceRevision"] == 0

    payload = body(revision)
    first = client.put(endpoint, headers=auth(admin), json=payload)
    replay = client.put(endpoint, headers=auth(admin), json=payload)
    assert first.status_code == replay.status_code == 200
    assert replay.json() == first.json()
    assert first.json()["preference"] == {
        "schemaVersion": 1,
        "ref": {
            "schemaVersion": 1,
            "coreId": app.state.core.context.coreId,
            "homeId": app.state.core.context.homeId,
            "accountId": admin["user"]["id"],
            "kind": "media_language_preferences",
        },
        "revision": 1,
        "audioLanguage": "tr-tr",
        "subtitleLanguage": "off",
    }

    create(client, admin, "listener")
    listener = activate(client, "listener")
    assert client.get(endpoint, headers=auth(listener)).json()["preference"] is None

    path = "/api/v1/media/language-preferences/{core_id}/{home_id}"
    schema = client.get("/api/v1/openapi.json", headers=auth(admin)).json()
    assert schema["paths"][path]["get"]["security"] == [{"DeviceAccessToken": []}]
    put = schema["paths"][path]["put"]
    assert put["security"] == [{"DeviceAccessToken": []}]
    request_schema = schema["components"]["schemas"]["PutMediaLanguagePreference"]
    assert set(request_schema["required"]) == {
        "schemaVersion",
        "requestId",
        "expectedAccountRevision",
        "expectedRevision",
        "audioLanguage",
        "subtitleLanguage",
    }

    with TestClient(create_app(settings)) as restarted:
        fresh = login(restarted, "admin", "Synthetic new password 2026").json()
        assert restarted.get(endpoint, headers=auth(fresh)).json()["preference"] == first.json()["preference"]


def test_malformed_replayed_and_authority_drift_inputs_fail_without_mutation(server):
    app, client, _settings, _clock = server
    pair = ready(server)
    endpoint = root(app)
    revision = account_revision(client, pair)

    for mutation in (
        {"schemaVersion": 1.0},
        {"expectedRevision": False},
        {"audioLanguage": "TR"},
        {"subtitleLanguage": "unknown value"},
        {"privateToken": "must-not-echo"},
    ):
        candidate = body(revision) | mutation
        response = client.put(endpoint, headers=auth(pair), json=candidate)
        assert response.status_code == 400
        assert "must-not-echo" not in response.text
    assert client.get(endpoint, headers=auth(pair)).json()["preference"] is None

    accepted = client.put(endpoint, headers=auth(pair), json=body(revision))
    assert accepted.status_code == 200
    changed_replay = client.put(
        endpoint,
        headers=auth(pair),
        json=body(revision, audio="en"),
    )
    assert (changed_replay.status_code, changed_replay.json()["error"]["code"]) == (
        409,
        "idempotency_conflict",
    )
    stale = client.put(
        endpoint,
        headers=auth(pair),
        json=body(revision, request="b" * 32, audio="en"),
    )
    assert (stale.status_code, stale.json()["error"]["code"]) == (
        409,
        "revision_conflict",
    )

    with app.state.core.db.transaction() as connection:
        connection.execute(
            "UPDATE users SET revision=revision+1 WHERE id=?", (pair["user"]["id"],)
        )
    drifted = client.put(
        endpoint,
        headers=auth(pair),
        json=body(revision, request="c" * 32, revision=1, audio="en"),
    )
    assert (drifted.status_code, drifted.json()["error"]["code"]) == (
        409,
        "revision_conflict",
    )
    assert client.get(endpoint, headers=auth(pair)).json()["preference"] == accepted.json()["preference"]


def test_private_bounded_storage_and_tamper_are_fail_closed(server):
    app, client, settings, _clock = server
    pair = ready(server)
    endpoint = root(app)
    revision = account_revision(client, pair)
    assert client.put(endpoint, headers=auth(pair), json=body(revision)).status_code == 200

    with app.state.core.db.connection() as connection:
        dump = "\n".join(connection.iterdump())
        record = connection.execute("SELECT * FROM media_language_preferences").fetchone()
        receipts = connection.execute("SELECT COUNT(*) FROM media_language_preference_receipts").fetchone()[0]
    assert "tr-tr" not in dump and "must-not-echo" not in dump
    assert len(record["nonce"]) == 12 and 16 <= len(record["ciphertext"]) <= 1024
    assert receipts == 1

    with app.state.core.db.transaction() as connection:
        connection.execute("UPDATE media_language_preferences SET ciphertext=X'00'")
    unavailable = client.get(endpoint, headers=auth(pair))
    assert (unavailable.status_code, unavailable.json()["error"]["code"]) == (
        503,
        "media_language_preference_storage_unavailable",
    )
    with pytest.raises(StartupError, match="media_language_preference_storage_invalid"):
        create_app(settings)
