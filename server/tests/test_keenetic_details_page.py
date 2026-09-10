"""Bounded, snapshot-bound public Keenetic network detail pages."""

from conftest import auth

from test_keenetic_resource_adapter import _snapshot, bind, setup


def rich_snapshot():
    value = _snapshot()
    value["interfaces"] = [
        {**value["interfaces"][0], "id": "ISP", "name": "Internet", "kind": "wan"},
        {**value["interfaces"][0], "id": "Bridge0", "name": "Ev ağı", "kind": "lan",
         "address": "192.168.1.1"},
        {**value["interfaces"][0], "id": "WifiMaster0/AccessPoint1",
         "name": "Misafir", "kind": "wifi", "guest": True,
         "ssid": "Larenor Guest", "band": "5", "channel": 44, "signalDbm": -61},
    ]
    value["hosts"] = [
        {**value["hosts"][0], "id": f"02:00:00:00:00:0{i}",
         "macAddress": f"02:00:00:00:00:0{i}", "name": f"Tablet {i}",
         "ipAddress": f"192.168.1.{20 + i}", "interfaceId": "Bridge0",
         "band": "5", "signalDbm": -50 - i}
        for i in range(1, 4)
    ]
    return value


def test_details_are_bounded_snapshot_pages_without_raw_mac_or_config(server):
    app, client, admin, resource, _service, base, public, body = setup(server)
    app.state.core.keenetic_resources._reader = lambda _connection, guard: (
        guard(), rich_snapshot()
    )[1]
    bind(client, admin, base, body)

    first = client.get(public + "/details", headers=auth(admin), params={"limit": 2})
    assert first.status_code == 200, first.text
    page = first.json()
    assert len(page["entries"]) == 2
    assert len(page["snapshot"]) == 64 and len(page["nextAfter"]) == 64
    assert "macAddress" not in first.text and "password" not in first.text

    entries = list(page["entries"])
    after = page["nextAfter"]
    while after is not None:
        response = client.get(public + "/details", headers=auth(admin), params={
            "limit": 2, "after": after, "expectedSnapshot": page["snapshot"],
        })
        assert response.status_code == 200, response.text
        tail = response.json()
        assert tail["snapshot"] == page["snapshot"]
        entries.extend(tail["entries"])
        after = tail["nextAfter"]
    assert [item["kind"] for item in entries] == [
        "interface", "interface", "interface", "client", "client", "client"
    ]
    wifi = next(item for item in entries if item.get("interfaceKind") == "wifi")
    assert (wifi["ssid"], wifi["band"], wifi["channel"], wifi["signalDbm"]) == (
        "Larenor Guest", "5", 44, -61
    )
    clients = [item for item in entries if item["kind"] == "client"]
    assert all(len(item["macHash"]) == 16 for item in clients)
    assert len({item["macHash"] for item in clients}) == len(clients)


def test_details_reject_cursor_without_snapshot_and_changed_snapshot(server):
    app, client, admin, _resource, _service, base, public, body = setup(server)
    current = rich_snapshot()
    app.state.core.keenetic_resources._reader = lambda _connection, guard: (
        guard(), current
    )[1]
    bind(client, admin, base, body)
    first = client.get(public + "/details", headers=auth(admin), params={"limit": 1}).json()
    assert client.get(public + "/details", headers=auth(admin), params={
        "after": first["nextAfter"], "limit": 1,
    }).status_code == 400

    app.state.core.keenetic_resources._cache.clear()
    current = {**rich_snapshot(), "hosts": []}
    changed = client.get(public + "/details", headers=auth(admin), params={
        "after": first["nextAfter"], "expectedSnapshot": first["snapshot"], "limit": 1,
    })
    assert changed.status_code == 409
    assert changed.json()["error"]["code"] == "keenetic_snapshot_changed"

    for params in ({"limit": 0}, {"limit": 101}, {"after": "../secret",
                   "expectedSnapshot": first["snapshot"]}):
        assert client.get(public + "/details", headers=auth(admin), params=params).status_code == 400
