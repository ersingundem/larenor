"""Bounded, private Keenetic mesh topology projection."""

import json

from conftest import auth
from larenor_server.keenetic_resources.transport import (
    KeeneticReadOnlyTransport,
    _mesh_topology,
)
from test_keenetic_readonly_transport import (
    CONNECTION,
    SECRET,
    ScriptedFactory,
    challenge,
    response,
)
from test_keenetic_resource_adapter import _snapshot, bind, setup


def upstream_topology():
    return {
        "controller": {"name": "Ana Keenetic", "model": "Titan (KN-1810)"},
        "members": [
            {
                "name": "Salon Genişletici",
                "model": "Buddy 6 (KN-3411)",
                "mac": "50:FF:20:00:00:3A",
                "status": "online",
                "backhaul": {
                    "uplink": "WifiMaster1/WifiStation0",
                    "bridge": "8000.50:ff:20:00:01:0e",
                    "cost": 50,
                },
            },
            {
                "name": "Mutfak Genişletici",
                "model": "Buddy 5 (KN-3311)",
                "mac": "50:FF:20:00:01:11",
                "status": "offline",
                "backhaul": {
                    "uplink": "GigabitEthernet0",
                    "bridge": "e000.50:ff:20:00:00:3a",
                    "cost": 55,
                },
            },
        ],
    }


def telemetry():
    value = _snapshot()
    value["interfaces"] = [
        {**value["interfaces"][0], "id": "ISP", "name": "Internet", "kind": "wan"},
        {**value["interfaces"][0], "id": "WifiMaster0/AccessPoint0",
         "name": "Ev 2.4", "kind": "wifi", "address": None,
         "ssid": "Larenor Home", "band": "2.4", "channel": 6, "signalDbm": -47},
        {**value["interfaces"][0], "id": "WifiMaster1/AccessPoint0",
         "name": "Ev 5", "kind": "wifi", "address": None,
         "ssid": "Larenor Home", "band": "5", "channel": 44, "signalDbm": -52},
    ]
    value["hosts"] = [
        {**value["hosts"][0], "id": "02:00:00:00:00:01",
         "macAddress": "02:00:00:00:00:01", "interfaceId": "WifiMaster0/AccessPoint0",
         "band": "2.4", "signalDbm": -58},
        {**value["hosts"][0], "id": "02:00:00:00:00:02",
         "macAddress": "02:00:00:00:00:02", "interfaceId": "WifiMaster1/AccessPoint0",
         "band": "5", "signalDbm": -61},
    ]
    return value


def test_fixed_read_only_mws_member_command_is_bounded_and_secret_free():
    raw = upstream_topology()
    reply = [
        {"version": {"title": "5.0.4", "model": "Titan (KN-1810)"}},
        {"mws": {"member": raw["members"]}},
    ]
    factory = ScriptedFactory(
        challenge(),
        response(b"", headers=(("Set-Cookie", "SESSION=ready456; Path=/prefix"),)),
        response(reply),
    )
    value = KeeneticReadOnlyTransport(factory=factory).read_topology(
        CONNECTION, lambda: None
    )
    assert value["controller"] == {
        "name": "Titan (KN-1810)", "model": "Titan (KN-1810)"
    }
    assert value["members"][0]["mac"] == raw["members"][0]["mac"]
    assert value["members"][0]["uplink"] == "WifiMaster1/WifiStation0"
    assert json.loads(factory.calls[2][4]) == [
        {"version": {}}, {"mws": {"member": {}}},
    ]
    assert SECRET not in repr(value) + repr(factory.calls)


def test_core_topology_hides_credentials_and_raw_macs_and_counts_wifi_clients(server):
    app, client, admin, resource, _service, base, public, body = setup(server)
    adapter = app.state.core.keenetic_resources
    adapter._reader = lambda _connection, guard: (guard(), telemetry())[1]
    adapter._topology_reader = lambda _connection, guard: (
        guard(), _mesh_topology(upstream_topology())
    )[1]
    bind(client, admin, base, body)
    result = client.get(public + "/topology", headers=auth(admin))
    assert result.status_code == 200, result.text
    snapshot = result.json()["topology"]
    assert snapshot["ref"] == resource["ref"]
    assert len(snapshot["nodes"]) == 3
    assert [item["role"] for item in snapshot["nodes"]] == [
        "controller", "extender", "extender"
    ]
    assert snapshot["nodes"][1]["backhaulType"] == "wifi_5"
    assert snapshot["nodes"][2]["online"] is False
    assert snapshot["nodes"][2]["parentId"] == snapshot["nodes"][1]["id"]
    assert [(item["band"], item["channel"], item["clientCount"])
            for item in snapshot["networks"]] == [("2.4", 6, 1), ("5", 44, 1)]
    assert "50:FF" not in result.text and "NEVER-PUBLISH" not in result.text


def test_topology_schema_drift_and_query_fail_closed(server):
    app, client, admin, _resource, _service, base, public, body = setup(server)
    adapter = app.state.core.keenetic_resources
    adapter._reader = lambda _connection, guard: (guard(), telemetry())[1]
    adapter._topology_reader = lambda _connection, guard: (
        guard(), {**upstream_topology(), "members": [{"mac": "raw"}]}
    )[1]
    bind(client, admin, base, body)
    response_value = client.get(public + "/topology", headers=auth(admin))
    assert response_value.status_code == 502
    assert response_value.json()["error"]["code"] == "keenetic_snapshot_unsupported"
    assert client.get(public + "/topology?raw=true", headers=auth(admin)).status_code == 400
