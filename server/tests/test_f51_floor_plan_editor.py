from tests.conftest import auth, ready
from tests.test_admin import activate, create
from tests.test_f51_floor_plan_http import _layout, _scope, _url


def _record(client, headers, registry, kind, label):
    response = client.post(registry, headers=headers,
                           json={"kind": kind, "label": label, "order": 0})
    assert response.status_code == 201
    return response.json()["record"]


def _body(catalog, layout, request_id="6" * 32):
    return {"requestId": request_id,
            "expectedLayoutRevision": catalog["layoutRevision"],
            "expectedEntityRegistryRevision": catalog["entityRegistryRevision"],
            "expectedResourceRevision": catalog["resourceRevision"],
            "expectedGrantRevision": catalog["grantRevision"], "layout": layout}


def test_editor_catalog_saves_real_targets_and_repairs_registry_drift(server):
    _app, client, _settings, _clock = server
    pair = ready(server)
    headers = auth(pair)
    scope = _scope(client, pair)
    url = _url(scope)
    registry = f"/api/v1/admin/home-resources/{scope['coreId']}/{scope['homeId']}"
    room = _record(client, headers, registry, "room", "Salon")
    resource = _record(client, headers, registry, "resource", "Salon TV")
    catalog = client.get(url + "/editor", headers=headers).json()
    assert catalog["layout"] is None and catalog["layoutRevision"] == 0
    assert catalog["rooms"] == [{"roomId": room["ref"]["id"], "label": "Salon", "revision": 1}]
    assert catalog["targets"] == [{"targetKind": "resource",
        "targetId": resource["ref"]["id"], "targetRevision": 1, "label": "Salon TV"}]
    layout = _layout(anchors=({"anchorId": "tv", "roomId": "living",
        "targetKind": "resource", "targetId": resource["ref"]["id"],
        "targetRevision": 1, "x": 0.5, "y": 0.5, "rotation": 45.0},))
    layout["rooms"][0]["roomId"] = room["ref"]["id"]
    layout["rooms"][0]["label"] = "Salon"
    layout["anchors"][0]["roomId"] = room["ref"]["id"]
    body = _body(catalog, layout)
    saved = client.put(url + "/editor", headers=headers, json=body)
    assert saved.status_code == 200
    assert client.put(url + "/editor", headers=headers, json=body).json() == saved.json()
    assert client.get(url, headers=headers).json()["layout"] == layout
    changed = client.patch(registry + "/" + resource["ref"]["id"], headers=headers,
        json={"label": "TV renamed", "order": 0, "expectedRevision": 1, "expectedAclRevision": 1})
    assert changed.status_code == 200
    assert client.get(url, headers=headers).status_code == 409
    assert client.put(url + "/editor", headers=headers,
        json=_body(catalog, layout, "7" * 32)).status_code == 409
    repair = client.get(url + "/editor", headers=headers)
    assert repair.status_code == 200
    current = repair.json()
    assert current["layout"] == layout
    assert current["targets"][0]["targetRevision"] == 2
    layout["anchors"][0]["targetRevision"] = 2
    repaired = client.put(url + "/editor", headers=headers,
        json=_body(current, layout, "8" * 32))
    assert repaired.status_code == 200
    loaded = client.get(url, headers=headers).json()
    assert loaded["layoutRevision"] == 2
    assert loaded["layout"]["vectors"] == layout["vectors"]
    assert loaded["layout"]["anchors"][0]["rotation"] == 45.0


def test_editor_rejects_member_wrong_scope_and_missing_cas_before_mutation(server):
    _app, client, _settings, _clock = server
    pair = ready(server)
    scope = _scope(client, pair)
    url = _url(scope)
    create(client, pair)
    member = activate(client, "member")
    assert client.get(url + "/editor", headers=auth(member)).status_code == 403
    assert client.put(url + "/editor", headers=auth(member),
        json=_body(client.get(url + "/editor", headers=auth(pair)).json(), _layout())).status_code == 403
    assert client.get(f"/api/v1/floor-plan/{'0' * 32}/{scope['homeId']}/editor",
        headers=auth(pair)).status_code == 404
    catalog = client.get(url + "/editor", headers=auth(pair)).json()
    body = _body(catalog, _layout())
    del body["expectedGrantRevision"]
    assert client.put(url + "/editor", headers=auth(pair), json=body).status_code == 400
    assert client.get(url + "/editor", headers=auth(pair)).json()["layoutRevision"] == 0


def test_editor_refuses_tampered_stale_geometry(server):
    app, client, _settings, _clock = server
    pair = ready(server)
    scope = _scope(client, pair)
    url = _url(scope)
    registry = f"/api/v1/admin/home-resources/{scope['coreId']}/{scope['homeId']}"
    room = _record(client, auth(pair), registry, "room", "Salon")
    layout = _layout()
    layout["rooms"][0]["roomId"] = room["ref"]["id"]
    layout["rooms"][0]["label"] = "Salon"
    catalog = client.get(url + "/editor", headers=auth(pair)).json()
    assert client.put(url + "/editor", headers=auth(pair),
        json=_body(catalog, layout)).status_code == 200
    with app.state.core.db.transaction() as connection:
        connection.execute("UPDATE floor_plan_layouts SET payload='{}'")
    response = client.get(url + "/editor", headers=auth(pair))
    assert response.status_code == 503
    assert response.json()["error"]["code"] == "server_unavailable"
