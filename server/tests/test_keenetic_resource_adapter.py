"""Central Keenetic telemetry uses only a packaged synthetic reader seam."""
from conftest import auth, ready
from test_admin import activate, create as create_user


def _snapshot():
    return {
        "status": {"online": True, "uptimeSeconds": 86400, "firmware": "4.3.6"},
        "interfaces": [{"id": "GigabitEthernet0", "name": "Internet", "kind": "wan",
                        "online": True, "address": "192.0.2.2", "rxBytes": 1200, "txBytes": 500}],
        "traffic": {"rxBytes": 1200, "txBytes": 500, "downloadBps": 90, "uploadBps": 30},
        "hosts": [{"id": "host-1", "name": "Tablet", "ipAddress": "192.0.2.20",
                   "macAddress": "02:00:00:00:00:01", "interfaceId": "GigabitEthernet0",
                   "online": True, "registered": True}],
    }


def setup(server):
    app, client, _, _ = server
    admin = ready(server); scope = app.state.core.context
    resource = client.post(f"/api/v1/admin/home-resources/{scope.coreId}/{scope.homeId}",
        headers=auth(admin), json={"kind": "resource", "label": "Router", "order": 0}).json()["record"]
    service = client.post("/api/v1/admin/services", headers=auth(admin), json={
        "kind": "keenetic", "name": "Synthetic router", "baseUrl": "https://router.invalid",
        "credentials": {"username": "fixture", "password": "NEVER-PUBLISH-SECRET"}}).json()["service"]
    service = app.state.core.services.record_verification(
        app.state.core.auth.authenticate(admin["accessToken"]), service["id"], 1,
        state="authenticated", version="4.3.6")["service"]
    suffix = f"/keenetic/{scope.coreId}/{scope.homeId}/resources/{resource['ref']['id']}"
    body = {"serviceId": service["id"], "expectedServiceRevision": service["revision"],
            "expectedResourceRevision": resource["revision"], "expectedAclRevision": resource["aclRevision"],
            "expectedBindingId": None}
    return app, client, admin, resource, service, "/api/v1/admin" + suffix, "/api/v1" + suffix, body


def bind(client, admin, base, body):
    preview = client.post(base + "/binding-preview", headers=auth(admin), json=body)
    assert preview.status_code == 201, preview.text
    result = preview.json()["preview"]
    confirmed = client.post(base + "/binding-confirm", headers=auth(admin),
                            json={"previewId": result["id"]})
    assert confirmed.status_code == 201, confirmed.text
    return result, confirmed.json()["binding"]


def test_admin_preview_confirm_and_authorized_cached_snapshot(server):
    app, client, admin, resource, service, base, public, body = setup(server)
    calls = []
    app.state.core.keenetic_resources._reader = lambda connection, guard: (calls.append(connection), guard(), _snapshot())[2]
    preview, binding = bind(client, admin, base, body)
    assert preview["snapshot"] == _snapshot()
    assert binding == preview["binding"]
    assert client.post(base + "/binding-confirm", headers=auth(admin),
                       json={"previewId": preview["id"]}).status_code == 409
    first = client.get(public + "/snapshot", headers=auth(admin))
    assert first.status_code == 200, first.text
    second = client.get(public + "/snapshot", headers=auth(admin))
    assert second.status_code == 200 and len(calls) == 2
    payload = first.json()["snapshot"]
    assert payload["ref"] == resource["ref"] and payload["bindingId"] == binding["id"]
    assert 0 < payload["remainingTtlMs"] <= 5000
    assert "NEVER-PUBLISH" not in first.text + str(calls)


def test_member_acl_and_user_scoped_cache_are_rechecked(server):
    app, client, admin, resource, _service, base, public, body = setup(server)
    calls = []
    app.state.core.keenetic_resources._reader = lambda _connection, guard: (guard(), calls.append(1), _snapshot())[2]
    bind(client, admin, base, body)
    create_user(client, admin); member = activate(client, "member")
    assert client.get(public + "/snapshot", headers=auth(member)).status_code == 404
    ref = resource["ref"]
    grant = f"/api/v1/admin/home-resources/{ref['coreId']}/{ref['homeId']}/{ref['id']}/grants/{member['user']['id']}"
    assert client.put(grant, headers=auth(admin), json={"expectedAclRevision": 1,
        "permissions": {"read": True, "write": False}}).status_code == 200
    assert client.get(public + "/snapshot", headers=auth(member)).status_code == 200
    assert len(calls) == 2
    assert client.delete(grant + "?expectedAclRevision=2", headers=auth(admin)).status_code == 204
    assert client.get(public + "/snapshot", headers=auth(member)).status_code == 404


def test_changed_service_and_late_authority_never_reuse_binding_or_cache(server):
    app, client, admin, resource, service, base, public, body = setup(server)
    adapter = app.state.core.keenetic_resources
    adapter._reader = lambda _connection, guard: (guard(), _snapshot())[1]
    bind(client, admin, base, body)
    changed = client.put(f"/api/v1/admin/services/{service['id']}", headers=auth(admin), json={
        "expectedRevision": 1, "name": "Changed", "baseUrl": "https://changed.invalid",
        "credentials": {"username": "changed", "password": "changed-secret"}})
    assert changed.status_code == 200
    assert client.get(public + "/snapshot", headers=auth(admin)).status_code == 409

    # A fresh fixture proves authority is checked again after the synthetic I/O seam.
    app, client, admin, resource, _service, base, public, body = setup(server)
    def late(_connection, guard):
        guard()
        with app.state.core.db.transaction() as c:
            c.execute("UPDATE users SET revision=revision+1 WHERE id=?", (admin["user"]["id"],))
        return _snapshot()
    app.state.core.keenetic_resources._reader = late
    assert client.post(base + "/binding-preview", headers=auth(admin), json=body).status_code == 401


def test_cancel_stale_preview_clock_rollback_and_invalid_upstream_fail_closed(server):
    app, client, admin, _resource, _service, base, public, body = setup(server)
    adapter = app.state.core.keenetic_resources
    adapter._reader = lambda _connection, guard: (guard(), _snapshot())[1]
    preview = client.post(base + "/binding-preview", headers=auth(admin), json=body).json()["preview"]
    assert client.delete(base + f"/binding-preview/{preview['id']}", headers=auth(admin)).status_code == 204
    assert client.post(base + "/binding-confirm", headers=auth(admin),
                       json={"previewId": preview["id"]}).status_code == 409
    _preview, _binding = bind(client, admin, base, body)
    assert client.get(public + "/snapshot", headers=auth(admin)).status_code == 200
    adapter._clock = lambda: 100.0; adapter._last_clock = 200.0
    adapter._reader = lambda _connection, guard: (guard(), {**_snapshot(), "status": {"online": "yes"}})[1]
    response = client.get(public + "/snapshot", headers=auth(admin))
    assert response.status_code == 502 and response.json()["error"]["code"] == "keenetic_snapshot_unsupported"


def test_unverified_or_unsupported_service_cannot_be_previewed(server):
    app, client, admin, resource, service, base, _public, body = setup(server)
    app.state.core.keenetic_resources._reader = lambda _connection, _guard: _snapshot()
    changed = client.put(f"/api/v1/admin/services/{service['id']}", headers=auth(admin), json={
        "expectedRevision": 1, "name": "Unverified", "baseUrl": service["baseUrl"],
        "credentials": {"username": "fixture", "password": "replacement"}}).json()["service"]
    body = {**body, "expectedServiceRevision": changed["revision"]}
    assert client.post(base + "/binding-preview", headers=auth(admin), json=body).status_code == 409
