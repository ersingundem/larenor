from tests.conftest import auth, ready


def _scope(client, pair):
    return client.get("/api/v1/context", headers=auth(pair)).json()


def _layout(*, anchors=()):
    return {
        "floors": [{"floorId": "ground", "label": "Ground floor", "order": 0}],
        "rooms": [{
            "roomId": "living",
            "floorId": "ground",
            "label": "Living room",
            "polygon": [
                {"x": 0.05, "y": 0.05},
                {"x": 0.95, "y": 0.05},
                {"x": 0.95, "y": 0.95},
            ],
        }],
        "anchors": list(anchors),
        "vectors": [{
            "shapeId": "north-wall",
            "floorId": "ground",
            "kind": "wall",
            "points": [{"x": 0.05, "y": 0.05}, {"x": 0.95, "y": 0.05}],
        }],
    }


def _url(scope):
    return f"/api/v1/floor-plan/{scope['coreId']}/{scope['homeId']}"


def test_authenticated_layout_round_trip_is_bounded_and_idempotent(server):
    app, client, _settings, _clock = server
    pair = ready(server)
    headers = auth(pair)
    scope = _scope(client, pair)
    body = {
        "requestId": "1" * 32,
        "expectedLayoutRevision": 0,
        "layout": _layout(),
    }

    saved = client.put(_url(scope), headers=headers, json=body)
    assert saved.status_code == 200
    assert saved.json() == {
        "receipt": {"requestId": "1" * 32, "revision": 1, "status": "saved"}
    }
    assert client.put(_url(scope), headers=headers, json=body).json() == saved.json()

    current = client.get(_url(scope), headers=headers)
    assert current.status_code == 200
    assert current.json()["layoutRevision"] == 1
    assert current.json()["layout"] == body["layout"]
    assert pair["accessToken"] not in current.text

    conflicting = {**body, "layout": _layout(anchors=())}
    conflicting["layout"]["floors"][0]["label"] = "Changed"
    assert client.put(_url(scope), headers=headers, json=conflicting).status_code == 409
    assert app.state.core.floor_plan is not None


def test_resource_anchors_are_resolved_and_revision_drift_fails_closed(server):
    _app, client, _settings, _clock = server
    pair = ready(server)
    headers = auth(pair)
    scope = _scope(client, pair)
    registry = f"/api/v1/admin/home-resources/{scope['coreId']}/{scope['homeId']}"
    resource = client.post(
        registry,
        headers=headers,
        json={"kind": "resource", "label": "Living TV", "order": 0},
    ).json()["record"]
    ref = resource["ref"]
    anchor = {
        "anchorId": "living-tv",
        "roomId": "living",
        "targetKind": "resource",
        "targetId": ref["id"],
        "targetRevision": resource["revision"],
        "x": 0.5,
        "y": 0.5,
        "rotation": 0.0,
    }
    body = {
        "requestId": "2" * 32,
        "expectedLayoutRevision": 0,
        "layout": _layout(anchors=(anchor,)),
    }
    assert client.put(_url(scope), headers=headers, json=body).status_code == 200

    changed = client.patch(
        registry + "/" + ref["id"],
        headers=headers,
        json={
            "label": "Living TV updated",
            "order": 0,
            "expectedRevision": resource["revision"],
            "expectedAclRevision": resource["aclRevision"],
        },
    )
    assert changed.status_code == 200
    stale = client.get(_url(scope), headers=headers)
    assert stale.status_code == 409
    assert stale.json() == {"error": {"code": "floor_plan_authority_changed"}}


def test_unknown_anchor_and_wrong_scope_never_leak_layout(server):
    _app, client, _settings, _clock = server
    pair = ready(server)
    headers = auth(pair)
    scope = _scope(client, pair)
    anchor = {
        "anchorId": "unknown",
        "roomId": "living",
        "targetKind": "resource",
        "targetId": "f" * 32,
        "targetRevision": 1,
        "x": 0.5,
        "y": 0.5,
        "rotation": 0.0,
    }
    denied = client.put(
        _url(scope),
        headers=headers,
        json={
            "requestId": "3" * 32,
            "expectedLayoutRevision": 0,
            "layout": _layout(anchors=(anchor,)),
        },
    )
    assert denied.status_code == 404
    assert denied.json() == {"error": {"code": "not_found"}}

    wrong = client.get(
        f"/api/v1/floor-plan/{'0' * 32}/{scope['homeId']}", headers=headers
    )
    assert wrong.status_code == 404
    assert wrong.json() == {"error": {"code": "not_found"}}
