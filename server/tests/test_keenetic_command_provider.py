import pytest

from conftest import auth
from larenor_server.errors import ApiError
from larenor_server.keenetic_commands.provider import KeeneticCommandStateProvider

from test_keenetic_command_authority import Actor, state
from test_keenetic_resource_adapter import _snapshot, bind, setup


def snapshot(**changes):
    value = _snapshot()
    value["status"].update({
        "firmwareRevision": 44,
        "statusRevision": 71,
    })
    value["interfaces"] = [
        {**value["interfaces"][0], "id": "ISP", "kind": "wan", "online": True},
        {**value["interfaces"][0], "id": "WifiMaster0/AccessPoint1",
         "name": "Guest", "kind": "wifi", "online": False, "guest": True},
    ]
    value["hosts"][0].update({"interfaceId": "ISP", "internetAccess": "allowed"})
    return {
        "ref": {"schemaVersion": 1, "kind": "resource", "id": "3" * 32,
                "coreId": "1" * 32, "homeId": "2" * 32},
        "bindingId": "4" * 32, "bindingRevision": 5,
        "serviceId": "5" * 32, "serviceRevision": 6,
        "resourceRevision": 7, "aclRevision": 8,
        "observedAt": "2026-09-11T10:00:00Z", "remainingTtlMs": 5000,
        "telemetry": value,
        **changes,
    }


class Resources:
    def __init__(self, value):
        self.value = value
        self.calls = []

    def snapshot(self, actor, core, home, resource, **options):
        self.calls.append((actor.id, core, home, resource, options))
        if isinstance(self.value, Exception):
            raise self.value
        return {"snapshot": self.value}


class Egress:
    def __init__(self, error=None):
        self.error = error
        self.calls = []

    def check_component(self, actor, service, revision, component):
        self.calls.append((actor.id, service, revision, component))
        if self.error:
            raise self.error


def provider(value=None, authorize=None, egress=None, actor_revision=None):
    source = Resources(value or snapshot())
    checks = []
    result = KeeneticCommandStateProvider(
        source,
        authorize=authorize or (lambda actor, target, action: checks.append(
            (actor.id, target.resourceId, action)
        )),
        actor_revision=actor_revision or (lambda _actor: 9),
        egress=egress or Egress(),
    )
    return result, source, checks


def test_exact_guest_client_and_wan_descriptors_include_full_revision_tuple():
    service, source, checks = provider()
    response = service.descriptors(Actor(), "1" * 32, "2" * 32, "3" * 32)
    descriptors = response["descriptors"]
    assert [item["target"]["targetKind"] for item in descriptors] == [
        "guest_wifi", "client", "wan"
    ]
    assert [item["actions"] for item in descriptors] == [
        ["guest_wifi_enable"], ["client_internet_pause"], ["wan_reconnect"]
    ]
    for item in descriptors:
        target = item["target"]
        assert (target["resourceRevision"], target["aclRevision"],
                target["bindingRevision"], target["serviceRevision"],
                target["firmwareRevision"], target["stateRevision"]) == (
                    7, 8, 5, 6, 44, 71
                )
        assert item["expectedUserRevision"] == 9
    assert source.calls[0][-1] == {"cancelled": source.calls[0][-1]["cancelled"],
                                  "bypass_cache": True}
    assert len(checks) == 3


@pytest.mark.parametrize("change", [
    {"remainingTtlMs": 0},
    {"telemetry": {**snapshot()["telemetry"], "status": {
        **snapshot()["telemetry"]["status"], "online": False}}},
    {"telemetry": {**snapshot()["telemetry"], "status": {
        **snapshot()["telemetry"]["status"], "firmwareRevision": None}}},
])
def test_stale_offline_or_schema_incomplete_snapshot_fails_closed(change):
    service, _, _ = provider(snapshot(**change))
    with pytest.raises(ApiError, match="keenetic_command_unavailable"):
        service.descriptors(Actor(), "1" * 32, "2" * 32, "3" * 32)


@pytest.mark.parametrize("late", ["permission", "egress", "source"])
def test_permission_egress_or_source_loss_after_read_is_never_returned(late):
    def authorize(_actor, _target, _action):
        if late == "permission":
            raise ApiError("forbidden", 403)

    egress = Egress(ApiError("outbound_denied", 403) if late == "egress" else None)
    value = ApiError("keenetic_upstream_unavailable", 502) if late == "source" else snapshot()
    service, _, _ = provider(value, authorize=authorize, egress=egress)
    with pytest.raises(ApiError, match="keenetic_command_unavailable"):
        service.descriptors(Actor(), "1" * 32, "2" * 32, "3" * 32)


def test_observe_accepts_only_an_exact_current_descriptor():
    service, _, _ = provider()
    descriptor = service.descriptors(
        Actor(), "1" * 32, "2" * 32, "3" * 32
    )["descriptors"][0]["target"]
    assert service.for_actor(Actor(), descriptor).model_dump(mode="json") == descriptor
    with pytest.raises(ApiError, match="keenetic_command_unavailable"):
        service.for_actor(
            Actor(), state().model_copy(update={"stateRevision": 999})
        )


def test_scope_ambiguity_or_user_revision_loss_fails_closed():
    duplicate = snapshot()
    duplicate["telemetry"]["hosts"].append({
        **duplicate["telemetry"]["hosts"][0],
        "id": "host-duplicate",
    })
    service, _, _ = provider(duplicate)
    with pytest.raises(ApiError, match="keenetic_command_unavailable"):
        service.descriptors(Actor(), "1" * 32, "2" * 32, "3" * 32)

    wrong_scope = snapshot()
    wrong_scope["ref"] = {**wrong_scope["ref"], "id": "9" * 32}
    service, _, _ = provider(wrong_scope)
    with pytest.raises(ApiError, match="keenetic_command_unavailable"):
        service.descriptors(Actor(), "1" * 32, "2" * 32, "3" * 32)

    revisions = iter((9, 10))
    service, _, _ = provider(actor_revision=lambda _actor: next(revisions))
    with pytest.raises(ApiError, match="keenetic_command_unavailable"):
        service.descriptors(Actor(), "1" * 32, "2" * 32, "3" * 32)


def test_admin_targets_route_uses_fresh_bound_resource_state(server):
    app, client, admin, resource, _service, base, _public, body = setup(server)
    telemetry = snapshot()["telemetry"]
    calls = []
    app.state.core.keenetic_resources._reader = lambda _connection, guard: (
        guard(), calls.append(1), telemetry
    )[2]
    bind(client, admin, base, body)
    app.state.core.keenetic_command_provider._egress = Egress()
    ref = resource["ref"]
    path = (
        f"/api/v1/admin/homes/{ref['coreId']}/{ref['homeId']}"
        f"/resources/{ref['id']}/keenetic/commands/targets"
    )
    response = client.get(path, headers=auth(admin))
    assert response.status_code == 200, response.text
    descriptors = response.json()["descriptors"]
    assert [item["target"]["targetKind"] for item in descriptors] == [
        "guest_wifi", "client", "wan"
    ]
    preview = client.post(path.removesuffix("/targets") + "/preview", headers=auth(admin), json={
        "schemaVersion": 1,
        "action": descriptors[0]["actions"][0],
        "target": descriptors[0]["target"],
        "expectedUserRevision": descriptors[0]["expectedUserRevision"],
        "requestId": "6" * 32,
        "idempotencyKey": "B" * 43,
        "reason": "Guest network schedule",
    })
    assert preview.status_code == 200, preview.text
    assert preview.json()["preview"]["target"] == descriptors[0]["target"]
    assert len(calls) == 3  # binding preview plus two forced-fresh command reads
