import json

from conftest import auth, login, ready
from fastapi.testclient import TestClient
from larenor_server.app import create_app
from test_admin import activate, create


def _root(app):
    context = app.state.core.context
    return (
        f"/api/v1/media/jellyfin/preferences/"
        f"{context.coreId}/{context.homeId}"
    )


def _put(client, pair, root, *, expected=0, audio="tr-tr", subtitle="off"):
    return client.put(
        root,
        headers=auth(pair),
        json={
            "schemaVersion": 1,
            "expectedRevision": expected,
            "audioLanguage": audio,
            "subtitleLanguage": subtitle,
        },
    )


def test_preferences_are_exact_core_account_scoped_revisioned_and_persistent(server):
    app, client, settings, _clock = server
    pair = ready(server)
    root = _root(app)

    assert client.get(root).status_code == 401
    empty = client.get(root, headers=auth(pair))
    assert empty.status_code == 200
    authority = empty.json()["authority"]
    assert authority == {
        "schemaVersion": 1,
        "coreId": app.state.core.context.coreId,
        "homeId": app.state.core.context.homeId,
        "accountId": pair["user"]["id"],
        "accountRevision": 2,
        "sessionFamilyId": authority["sessionFamilyId"],
    }
    assert empty.json()["preference"] is None

    created = _put(client, pair, root)
    assert created.status_code == 200
    assert created.json()["preference"] == {
        "schemaVersion": 1,
        "ref": {
            "schemaVersion": 1,
            "coreId": authority["coreId"],
            "homeId": authority["homeId"],
            "accountId": authority["accountId"],
            "kind": "jellyfin_track_preferences",
        },
        "revision": 1,
        "audioLanguage": "tr-tr",
        "subtitleLanguage": "off",
    }
    assert client.get(root, headers=auth(pair)).json() == created.json()

    stale = _put(client, pair, root, expected=0, audio="en")
    assert (stale.status_code, stale.json()["error"]["code"]) == (
        409,
        "revision_conflict",
    )
    wrong_core = root.replace(authority["coreId"], "f" * 32)
    assert client.get(wrong_core, headers=auth(pair)).status_code == 404
    assert "token" not in json.dumps(created.json()).lower()
    assert "url" not in json.dumps(created.json()).lower()

    with TestClient(create_app(settings)) as restarted:
        fresh = login(restarted, "admin", "Synthetic new password 2026").json()
        restored = restarted.get(root, headers=auth(fresh))
        assert restored.status_code == 200
        assert restored.json()["preference"] == created.json()["preference"]


def test_preferences_are_private_to_each_current_account(server):
    app, client, _settings, _clock = server
    admin = ready(server)
    create(client, admin, "listener")
    member = activate(client, "listener")
    root = _root(app)

    assert _put(client, admin, root, audio="en", subtitle=None).status_code == 200
    assert client.get(root, headers=auth(member)).json()["preference"] is None
    member_saved = _put(client, member, root, audio="tr", subtitle="off")
    assert member_saved.status_code == 200
    assert member_saved.json()["preference"]["audioLanguage"] == "tr"
    assert client.get(root, headers=auth(admin)).json()["preference"][
        "audioLanguage"
    ] == "en"


def test_malformed_or_corrupt_preferences_fail_closed(server):
    app, client, _settings, _clock = server
    pair = ready(server)
    root = _root(app)

    invalid = _put(client, pair, root, audio="NOT valid", subtitle=None)
    assert invalid.status_code == 400
    assert _put(client, pair, root, audio="en", subtitle=None).status_code == 200
    with app.state.core.db.transaction() as connection:
        connection.execute(
            "UPDATE jellyfin_track_preferences SET audio_language='tr'"
        )
    corrupt = client.get(root, headers=auth(pair))
    assert (corrupt.status_code, corrupt.json()["error"]["code"]) == (
        503,
        "media_preference_storage_unavailable",
    )
