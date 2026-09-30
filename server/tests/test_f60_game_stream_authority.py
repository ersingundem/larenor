import hashlib
import json
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from conftest import auth, ready
from larenor_server.app import create_app
from larenor_server.errors import StartupError
from larenor_server.game_streaming.schema import LEGACY_TABLES

CONTRACT = Path(__file__).parents[2] / "docs/contracts/f60-game-streaming-v2.json"


def _root(app):
    context = app.state.core.context
    return f"/api/v1/game-streaming/{context.coreId}/{context.homeId}"


def _revision(app, account_id):
    with app.state.core.db.connection() as connection:
        return connection.execute(
            "SELECT revision FROM users WHERE id=?", (account_id,)).fetchone()[0]


def _catalog():
    apps = [{"observationId": "6" * 32, "revision": 1, "name": "Desktop"}]
    return apps, _catalog_digest(apps)


def _catalog_digest(apps):
    return hashlib.sha256(json.dumps(
        apps, separators=(",", ":"), sort_keys=True).encode()).hexdigest()


def _pair(client, headers, root, account_revision, now=1788609600.0):
    intent = {"schemaVersion": 2, "requestKey": "pairing-request-0001",
              "accountRevision": account_revision, "expiresAt": now + 60.0}
    created = client.post(root + "/pairings", headers=headers, json=intent)
    assert created.status_code == 201, created.text
    pairing = created.json()
    assert pairing["pairingGrant"]
    assert client.post(root + "/pairings", headers=headers, json=intent).json()[
        "pairingGrant"] is None
    apps, digest = _catalog()
    observation = {"schemaVersion": 1, "receiptId": "3" * 32,
                   "nativeBindingId": "4" * 32, "bindingRevision": 1,
                   "engineRevision": "moonlight-12.2-b48494cb",
                   "provider": "moonlight-nvhttp", "state": "paired",
                   "hostObservationId": "5" * 32, "name": "Owned fixture",
                   "codecs": ["h264", "hevc"], "maxWidth": 3840,
                   "maxHeight": 2160, "maxFps": 120,
                   "catalogRevision": 1, "catalogDigest": digest, "apps": apps}
    body = {"schemaVersion": 2, "expectedPairingRevision": 1,
            "pairingGrant": pairing["pairingGrant"], "observation": observation}
    completed = client.post(
        root + f"/pairings/{pairing['id']}/complete", headers=headers, json=body)
    assert completed.status_code == 200, completed.text
    return pairing, completed.json(), body


def _quality(**changes):
    return {"codec": "hevc", "codecId": "a" * 32, "codecRevision": 1,
            "displayId": 0, "displayRevision": 6,
            "networkId": "b" * 32, "networkRevision": 7,
            "policyId": "c" * 32, "policyRevision": 8,
            "widthPixels": 1920, "heightPixels": 1080,
            "framesPerSecond": 60, "bitrateKbps": 20000,
            "frameQueueDepth": 2, "inputQueueDepth": 8,
            "secureSurface": True, **changes}


def _open(client, headers, root, registration, account_revision, now=1788609600.0,
          **changes):
    host, app = registration["host"], registration["apps"][0]
    body = {"schemaVersion": 2, "requestKey": "session-request-0001",
            "expectedHostRevision": host["revision"],
            "expectedPairingRevision": host["pairingRevision"],
            "expectedCatalogRevision": host["catalogRevision"],
            "expectedAppRevision": app["revision"],
            "accountRevision": account_revision,
            "clientAuthority": {"routeRevision": 4, "lifecycleRevision": 5,
                "displayRevision": 6, "networkRevision": 7, "policyRevision": 8},
            "selectedQuality": _quality(), "expiresAt": now + 600.0, **changes}
    return client.post(
        root + f"/hosts/{host['id']}/apps/{app['id']}/sessions",
        headers=headers, json=body)


def _setup(server):
    app, client, _settings, clock = server
    actor = ready(server)
    headers = auth(actor)
    root = _root(app)
    revision = _revision(app, actor["user"]["id"])
    pairing, registration, completion = _pair(
        client, headers, root, revision, clock.now)
    return app, client, clock, actor, headers, root, revision, pairing, registration, completion


def test_published_v2_contract_is_strict_secret_free_and_web_safe():
    contract = json.loads(CONTRACT.read_text())
    assert contract["schemaVersion"] == 2
    assert contract["assurance"] == "native_observed"
    assert contract["session"]["open"]["request"]["selectedQuality"] == _quality()
    assert contract["pairingIntent"]["complete"]["request"]["observation"][
        "catalogDigest"] == _catalog()[1]

    def integers(value):
        if type(value) is int:
            yield value
        elif isinstance(value, dict):
            for nested in value.values():
                yield from integers(nested)
        elif isinstance(value, list):
            for nested in value:
                yield from integers(nested)

    assert all(abs(value) <= 2**53 - 1 for value in integers(contract))
    encoded = json.dumps(contract).lower()
    for forbidden in ("host address", "pairing pin", "client private key",
                      "native binding handle"):
        assert forbidden in encoded


def test_pairing_intent_precedes_native_observation_and_public_registry_is_secret_free(server):
    app, client, _clock, _actor, headers, root, revision, pairing, result, completion = _setup(server)
    assert result["host"]["assurance"] == "native_observed"
    assert result["registrationMapping"] == {
        "nativeReceiptId": "3" * 32, "hostId": result["host"]["id"],
        "apps": [{"entryIndex": 0, "appId": result["apps"][0]["id"]}]}
    contract = json.loads(CONTRACT.read_text())
    example = contract["pairingIntent"]["complete"]["response"]
    assert set(result) == set(example)
    assert set(result["host"]) == set(example["host"])
    assert set(result["apps"][0]) == set(example["apps"][0])
    public = json.dumps(client.get(root + "/hosts", headers=headers).json())
    for secret in ("nativeBindingId", "hostObservationId", "receiptId",
                   "credential", "certificate", "address", "pin"):
        assert secret.lower() not in public.lower()
    with app.state.core.db.connection() as connection:
        stored = json.dumps({
            table: [dict(row) for row in connection.execute(f"SELECT * FROM {table}")]
            for table in ("game_stream_pairings", "game_stream_hosts", "game_stream_apps")
        })
    for native_identifier in ("4" * 32, "5" * 32, "6" * 32):
        assert native_identifier not in stored
    catalog = client.get(
        root + f"/hosts/{result['host']['id']}/apps", headers=headers)
    assert catalog.status_code == 200
    assert catalog.json()["apps"] == result["apps"]
    assert client.post(root + "/hosts", headers=headers, json={}).status_code == 405

    changed = {**completion, "observation": {
        **completion["observation"], "catalogDigest": "f" * 64}}
    bad = client.post(
        root + f"/pairings/{pairing['id']}/complete", headers=headers, json=changed)
    assert bad.status_code == 409
    assert revision <= 2**53 - 1


def test_successful_pairing_can_publish_an_empty_native_catalog(server):
    app, client, _settings, clock = server
    actor = ready(server)
    headers = auth(actor)
    root = _root(app)
    revision = _revision(app, actor["user"]["id"])
    pairing = client.post(root + "/pairings", headers=headers, json={
        "schemaVersion": 2, "requestKey": "empty-pairing-catalog",
        "accountRevision": revision, "expiresAt": clock.now + 60.0}).json()
    completed = client.post(root + f"/pairings/{pairing['id']}/complete",
        headers=headers, json={"schemaVersion": 2, "expectedPairingRevision": 1,
            "pairingGrant": pairing["pairingGrant"], "observation": {
                "schemaVersion": 1, "receiptId": "3" * 32,
                "nativeBindingId": "4" * 32, "bindingRevision": 1,
                "engineRevision": "moonlight-empty-catalog",
                "provider": "moonlight-nvhttp", "state": "paired",
                "hostObservationId": "5" * 32, "name": "Empty fixture",
                "codecs": ["h264"], "maxWidth": 1920, "maxHeight": 1080,
                "maxFps": 60, "catalogRevision": 1,
                "catalogDigest": _catalog_digest([]), "apps": []}})
    assert completed.status_code == 200, completed.text
    result = completed.json()
    assert result["apps"] == []
    assert result["registrationMapping"]["apps"] == []
    assert client.get(root + f"/hosts/{result['host']['id']}/apps",
                      headers=headers).json()["apps"] == []


def test_pairing_grant_scope_expiry_and_catalog_digest_fail_closed(server):
    app, client, _settings, clock = server
    actor = ready(server)
    headers = auth(actor)
    root = _root(app)
    revision = _revision(app, actor["user"]["id"])
    unsafe = client.post(root + "/pairings", headers=headers, json={
        "schemaVersion": 2, "requestKey": "pairing-unsafe-revision",
        "accountRevision": 2**53, "expiresAt": clock.now + 60.0})
    assert unsafe.status_code == 400
    intent = {"schemaVersion": 2, "requestKey": "pairing-request-0002",
              "accountRevision": revision, "expiresAt": clock.now + 60.0}
    pairing = client.post(root + "/pairings", headers=headers, json=intent).json()
    apps, _digest = _catalog()
    observation = {"schemaVersion": 1, "receiptId": "3" * 32,
        "nativeBindingId": "4" * 32, "bindingRevision": 1,
        "engineRevision": "moonlight-fixture", "provider": "moonlight-nvhttp",
        "state": "paired", "hostObservationId": "5" * 32, "name": "Fixture",
        "codecs": ["h264"], "maxWidth": 1920, "maxHeight": 1080,
        "maxFps": 60, "catalogRevision": 1, "catalogDigest": "0" * 64,
        "apps": apps}
    other = client.post("/api/v1/auth/login", json={
        "username": "admin", "password": "Synthetic new password 2026",
        "deviceName": "Other pairing family"}).json()
    wrong_family = client.post(root + f"/pairings/{pairing['id']}/complete",
        headers=auth(other), json={"schemaVersion": 2,
            "expectedPairingRevision": 1, "pairingGrant": pairing["pairingGrant"],
            "observation": {**observation, "catalogDigest": _catalog()[1]}})
    assert wrong_family.status_code == 404
    independent = client.post(root + "/pairings", headers=auth(other), json=intent)
    assert independent.status_code == 201
    assert independent.json()["id"] != pairing["id"]
    assert independent.json()["pairingGrant"] not in {None, pairing["pairingGrant"]}
    invalid = client.post(root + f"/pairings/{pairing['id']}/complete",
        headers=headers, json={"schemaVersion": 2, "expectedPairingRevision": 1,
            "pairingGrant": pairing["pairingGrant"], "observation": observation})
    assert invalid.status_code == 400
    clock.now += 61
    expired = client.post(root + f"/pairings/{pairing['id']}/complete",
        headers=headers, json={"schemaVersion": 2, "expectedPairingRevision": 1,
            "pairingGrant": pairing["pairingGrant"], "observation": {
                **observation, "catalogDigest": _catalog()[1]}})
    assert expired.status_code == 409


def test_session_binds_catalog_app_client_and_selected_quality(server):
    app, client, clock, actor, headers, root, revision, _pairing, registration, _ = _setup(server)
    too_large = _open(client, headers, root, registration, revision, clock.now,
                      selectedQuality=_quality(widthPixels=4096))
    assert too_large.status_code == 409
    mismatch = _open(client, headers, root, registration, revision, clock.now,
                     selectedQuality=_quality(displayRevision=9))
    assert mismatch.status_code == 400
    opened = _open(client, headers, root, registration, revision, clock.now)
    assert opened.status_code == 201, opened.text
    session = opened.json()
    assert set(session) == set(json.loads(CONTRACT.read_text())[
        "session"]["open"]["response"])
    assert session["selectedQuality"] == _quality()
    assert session["coreAuthority"]["selectedQuality"] == _quality()
    assert client.get(root + f"/sessions/{session['id']}", headers=headers).json() == session
    assert _open(client, headers, root, registration, revision, clock.now).json() == session

    other = client.post("/api/v1/auth/login", json={
        "username": "admin", "password": "Synthetic new password 2026",
        "deviceName": "Other family"}).json()
    denied = client.get(root + f"/sessions/{session['id']}", headers=auth(other))
    assert denied.status_code == 404
    assert client.get(root + "/hosts", headers=auth(other)).json()["hosts"] == []
    denied_catalog = client.get(
        root + f"/hosts/{registration['host']['id']}/apps", headers=auth(other))
    assert denied_catalog.status_code == 404


def test_native_catalog_refresh_is_two_phase_preserves_ids_and_retires_old_sessions(server):
    app, client, clock, actor, headers, root, revision, _pairing, registration, _ = _setup(server)
    host = registration["host"]
    original_app = registration["apps"][0]
    session = _open(client, headers, root, registration, revision, clock.now).json()
    issued = client.post(root + f"/sessions/{session['id']}/commands",
        headers=headers, json={"schemaVersion": 2,
            "requestKey": "catalog-pending-command", "expectedSessionRevision": 1,
            "intent": "stream"}).json()
    intent_body = {"schemaVersion": 2, "requestKey": "catalog-request-0001",
        "expectedHostRevision": host["revision"],
        "expectedPairingRevision": host["pairingRevision"],
        "expectedCatalogRevision": host["catalogRevision"],
        "accountRevision": revision, "expiresAt": clock.now + 60.0}
    intent_url = root + f"/hosts/{host['id']}/catalog-observations"
    created = client.post(intent_url, headers=headers, json=intent_body)
    assert created.status_code == 201, created.text
    intent = created.json()
    assert intent["catalogGrant"]
    contract = json.loads(CONTRACT.read_text())["catalog"]["refresh"]
    assert set(intent) == set(contract["create"]["firstResponseOnly"])
    assert client.post(intent_url, headers=headers, json=intent_body).json()[
        "catalogGrant"] is None

    other = client.post("/api/v1/auth/login", json={
        "username": "admin", "password": "Synthetic new password 2026",
        "deviceName": "Other catalog family"}).json()
    assert client.post(intent_url, headers=auth(other), json={
        **intent_body, "requestKey": "other-family-catalog"}).status_code == 404

    observed_apps = [
        {"observationId": "6" * 32, "revision": 2, "name": "Desktop updated"},
        {"observationId": "7" * 32, "revision": 1, "name": "New game"},
    ]
    completion = {"schemaVersion": 2, "expectedObservationRevision": 1,
        "catalogGrant": intent["catalogGrant"], "observation": {
            "schemaVersion": 1, "receiptId": "8" * 32,
            "nativeBindingId": "4" * 32, "bindingRevision": 1,
            "catalogRevision": 2, "catalogDigest": _catalog_digest(observed_apps),
            "apps": observed_apps}}
    complete_url = intent_url + f"/{intent['id']}/complete"
    assert client.post(complete_url, headers=auth(other), json=completion).status_code == 404
    refreshed = client.post(complete_url, headers=headers, json=completion)
    assert refreshed.status_code == 200, refreshed.text
    page = refreshed.json()
    assert set(page) == set(contract["complete"]["response"])
    assert set(page["registrationMapping"]) == set(
        contract["complete"]["response"]["registrationMapping"])
    assert page["catalogRevision"] == 2
    assert page["apps"][0]["id"] == original_app["id"]
    assert page["apps"][0]["revision"] == 2
    assert page["apps"][1]["id"] != original_app["id"]
    assert client.post(complete_url, headers=headers, json=completion).json() == page
    with app.state.core.db.connection() as connection:
        assert connection.execute(
            "SELECT state FROM game_stream_sessions WHERE id=?",
            (session["id"],)).fetchone()[0] == "retired"
        assert connection.execute(
            "SELECT state FROM game_stream_commands WHERE id=?",
            (issued["command"]["id"],)).fetchone()[0] == "unknown"

    # A later native catalog can remove an app while preserving the remaining ID.
    second_intent = client.post(intent_url, headers=headers, json={
        **intent_body, "requestKey": "catalog-request-0002",
        "expectedCatalogRevision": 2}).json()
    remaining = [observed_apps[1]]
    second = client.post(intent_url + f"/{second_intent['id']}/complete",
        headers=headers, json={"schemaVersion": 2, "expectedObservationRevision": 1,
            "catalogGrant": second_intent["catalogGrant"], "observation": {
                "schemaVersion": 1, "receiptId": "9" * 32,
                "nativeBindingId": "4" * 32, "bindingRevision": 1,
                "catalogRevision": 3, "catalogDigest": _catalog_digest(remaining),
                "apps": remaining}})
    assert second.status_code == 200, second.text
    assert second.json()["apps"] == [page["apps"][1]]
    with app.state.core.db.connection() as connection:
        assert connection.execute(
            "SELECT active FROM game_stream_apps WHERE id=?",
            (original_app["id"],)).fetchone()[0] == 0

    # The last native app may disappear; an empty observation retires it too.
    third_intent = client.post(intent_url, headers=headers, json={
        **intent_body, "requestKey": "catalog-request-0003",
        "expectedCatalogRevision": 3}).json()
    empty = client.post(intent_url + f"/{third_intent['id']}/complete",
        headers=headers, json={"schemaVersion": 2, "expectedObservationRevision": 1,
            "catalogGrant": third_intent["catalogGrant"], "observation": {
                "schemaVersion": 1, "receiptId": "a" * 32,
                "nativeBindingId": "4" * 32, "bindingRevision": 1,
                "catalogRevision": 4, "catalogDigest": _catalog_digest([]),
                "apps": []}})
    assert empty.status_code == 200, empty.text
    assert empty.json()["apps"] == []
    assert empty.json()["registrationMapping"]["apps"] == []
    with app.state.core.db.connection() as connection:
        assert connection.execute(
            "SELECT COUNT(*) FROM game_stream_apps WHERE host_id=? AND active=1",
            (host["id"],)).fetchone()[0] == 0


def test_dispatch_grant_is_one_use_and_lost_ack_becomes_unknown(server):
    app, client, clock, actor, headers, root, revision, _pairing, registration, _ = _setup(server)
    session = _open(client, headers, root, registration, revision, clock.now).json()
    url = root + f"/sessions/{session['id']}/commands"
    body = {"schemaVersion": 2, "requestKey": "command-request-0001",
            "expectedSessionRevision": 1, "intent": "stream"}
    issued = client.post(url, headers=headers, json=body)
    assert issued.status_code == 201
    assert issued.json()["dispatchGrant"]
    replay = client.post(url, headers=headers, json=body)
    assert replay.json()["dispatchGrant"] is None
    assert replay.json()["command"]["state"] == "unknown"
    assert client.post(url, headers=headers, json={
        **body, "requestKey": "command-request-0002"}).status_code == 409


def test_native_observation_is_exact_monotonic_and_never_provider_verified(server):
    app, client, clock, actor, headers, root, revision, _pairing, registration, _ = _setup(server)
    session = _open(client, headers, root, registration, revision, clock.now).json()
    commands = root + f"/sessions/{session['id']}/commands"
    issued = client.post(commands, headers=headers, json={
        "schemaVersion": 2, "requestKey": "command-request-0001",
        "expectedSessionRevision": 1, "intent": "stream"}).json()
    assert set(issued["command"]) == set(json.loads(CONTRACT.read_text())[
        "command"]["authorize"]["firstResponseOnly"]["command"])
    complete = commands + f"/{issued['command']['id']}/complete"
    body = {"schemaVersion": 2, "expectedSessionRevision": 1,
            "dispatchGrant": issued["dispatchGrant"], "state": "native_observed",
            "result": "streaming", "observationKind": "connectionStarted",
            "readbackRevision": 12, "nativeReceiptDigest": "d" * 64}
    other = client.post("/api/v1/auth/login", json={
        "username": "admin", "password": "Synthetic new password 2026",
        "deviceName": "Other command family"}).json()
    assert client.post(complete, headers=auth(other), json=body).status_code == 404
    receipt = client.post(complete, headers=headers, json=body)
    assert receipt.status_code == 200, receipt.text
    assert receipt.json()["state"] == "native_observed"
    assert "verified" not in json.dumps(receipt.json())
    assert client.post(complete, headers=headers, json=body).json() == receipt.json()
    assert client.post(complete, headers=headers, json={
        **body, "readbackRevision": 13}).status_code == 409

    second = client.post(commands, headers=headers, json={
        "schemaVersion": 2, "requestKey": "command-request-0002",
        "expectedSessionRevision": 1, "intent": "wake"}).json()
    stale = client.post(commands + f"/{second['command']['id']}/complete",
        headers=headers, json={**body, "dispatchGrant": second["dispatchGrant"],
            "result": "hostAwake", "observationKind": "serverInfoOnline"})
    assert stale.status_code == 409


def test_restart_marks_issued_command_unknown_and_never_regrants(server):
    app, client, settings, clock = server
    actor = ready(server)
    headers = auth(actor)
    root = _root(app)
    revision = _revision(app, actor["user"]["id"])
    _pairing, registration, _ = _pair(client, headers, root, revision, clock.now)
    session = _open(client, headers, root, registration, revision, clock.now).json()
    url = root + f"/sessions/{session['id']}/commands"
    body = {"schemaVersion": 2, "requestKey": "command-request-restart",
            "expectedSessionRevision": 1, "intent": "launch"}
    issued = client.post(url, headers=headers, json=body).json()
    with TestClient(create_app(settings)) as restarted:
        read = restarted.get(
            url + f"/{issued['command']['id']}", headers=headers)
        assert read.status_code == 200
        assert read.json()["state"] == "unknown"
        replay = restarted.post(url, headers=headers, json=body)
        assert replay.json()["dispatchGrant"] is None
        assert replay.json()["command"]["state"] == "unknown"


def test_revoke_retires_sessions_and_reports_local_cleanup_truthfully(server):
    app, client, clock, actor, headers, root, revision, _pairing, registration, _ = _setup(server)
    host = registration["host"]
    session = _open(client, headers, root, registration, revision, clock.now).json()
    revoke_body = {
        "schemaVersion": 2, "requestKey": "revoke-request-0001",
        "expectedHostRevision": host["revision"],
        "expectedPairingRevision": host["pairingRevision"],
        "expectedCatalogRevision": host["catalogRevision"]}
    other = client.post("/api/v1/auth/login", json={
        "username": "admin", "password": "Synthetic new password 2026",
        "deviceName": "Other revoke family"}).json()
    assert client.post(root + f"/hosts/{host['id']}/revoke",
                       headers=auth(other), json=revoke_body).status_code == 404
    revocation = client.post(root + f"/hosts/{host['id']}/revoke",
                             headers=headers, json=revoke_body)
    assert revocation.status_code == 201, revocation.text
    assert revocation.json()["state"] == "core_retired"
    assert client.get(root + f"/sessions/{session['id']}", headers=headers).status_code == 409
    final_url = (root + f"/hosts/{host['id']}/revocations/"
                 f"{revocation.json()['id']}/complete")
    unknown = client.post(final_url, headers=headers, json={
        "schemaVersion": 2, "state": "unknown"})
    assert unknown.json()["state"] == "unknown"
    assert client.post(final_url, headers=headers, json={
        "schemaVersion": 2, "state": "local_cleared"}).status_code == 409


def test_v1_caller_declared_registry_is_retired_not_promoted(server):
    app, _client, settings, _clock = server
    with app.state.core.db.transaction() as connection:
        for name in ("game_stream_commands", "game_stream_sessions", "game_stream_apps",
                     "game_stream_catalog_observations", "game_stream_hosts",
                     "game_stream_pairings", "game_stream_revocations"):
            connection.execute(f"DROP TABLE {name}")
        for statement in LEGACY_TABLES.values():
            connection.execute(statement)
        connection.execute("UPDATE metadata SET value='1' WHERE key='game_stream_schema'")
    restarted = create_app(settings)
    with restarted.state.core.db.connection() as connection:
        assert connection.execute("SELECT COUNT(*) FROM game_stream_hosts").fetchone()[0] == 0
        assert connection.execute(
            "SELECT value FROM metadata WHERE key='game_stream_schema'").fetchone()[0] == "2"


def test_storage_tamper_fails_closed_on_restart(server):
    app, client, settings, clock = server
    actor = ready(server)
    root = _root(app)
    client.post(root + "/pairings", headers=auth(actor), json={
        "schemaVersion": 2, "requestKey": "pairing-tamper-0001",
        "accountRevision": _revision(app, actor["user"]["id"]),
        "expiresAt": clock.now + 60.0})
    with app.state.core.db.transaction() as connection:
        connection.execute("UPDATE game_stream_pairings SET state='retired'")
    with pytest.raises(StartupError, match="game_stream_storage_invalid"):
        create_app(settings)
