from dataclasses import dataclass

from larenor_server.camera_search.api import CameraSearchRuntime
from larenor_server.camera_search.index import CameraSearchIndex
from larenor_server.camera_search.models import (
    CameraMetadataRecord,
    CameraSearchAuthority,
)

from conftest import auth, ready


CAMERA = "d" * 32
OTHER_CAMERA = "e" * 32


@dataclass
class Installed:
    authority: CameraSearchAuthority
    current: list[CameraSearchAuthority]


def _record(context, *, clip: str, visibility="household", owner=None):
    return CameraMetadataRecord(
        schemaVersion=1,
        coreId=context.coreId,
        homeId=context.homeId,
        clipId=clip * 32,
        eventId=("f" if clip == "1" else "9") * 32,
        cameraId=CAMERA,
        captureRevision=4,
        startMs=1788609600000,
        endMs=1788609660000,
        evidenceOffsetMs=10000,
        visibility=visibility,
        ownerAccountId=owner,
        labels=["parcel", "door"],
        summary="A red parcel was left by the door",
    )


def _install(app, pair, *, planner=None):
    principal = app.state.core.auth.authenticate(pair["accessToken"])
    context = app.state.core.context
    authority = CameraSearchAuthority(
        schemaVersion=1,
        coreId=context.coreId,
        homeId=context.homeId,
        homeRevision=3,
        accountId=principal.id,
        accountRevision=5,
        memberRevision=7,
        sessionFamilyId=principal.family_id,
        role=principal.role,
        accessibleCameraIds=[CAMERA],
        allowPrivateEvidence=False,
        active=True,
        canSearch=True,
    )
    current = [authority]
    index = CameraSearchIndex(
        [
            _record(context, clip="1"),
            _record(context, clip="2", visibility="private", owner="8" * 32),
        ],
        revision=11,
        cursorKey=b"f41-camera-search-fixture-key-32b",
        authorityResolver=lambda account_id: (
            current[0] if account_id == current[0].accountId else None
        ),
        queryPlanner=planner,
    )
    app.state.camera_search_runtime = CameraSearchRuntime(
        index=index,
        authorityResolver=lambda actor, core_id, home_id: current[0],
    )
    return principal, Installed(authority, current)


def _body(**updates):
    value = {
        "schemaVersion": 1,
        "query": "red parcel at the door",
        "expectedIndexRevision": 11,
        "startMs": 1788609500000,
        "endMs": 1788609700000,
        "cameraIds": [CAMERA],
        "pageSize": 30,
        "cursor": None,
    }
    value.update(updates)
    return value


def test_route_binds_authenticated_account_home_camera_and_private_scope(server):
    app, client, _settings, _clock = server
    pair = ready(server)
    context = app.state.core.context
    path = f"/api/v1/camera-search/{context.coreId}/{context.homeId}/search"

    assert client.post(path, json=_body()).status_code == 401
    unavailable = client.post(path, headers=auth(pair), json=_body())
    assert unavailable.status_code == 503
    assert unavailable.json()["error"]["code"] == "service_unavailable"

    _principal, installed = _install(app, pair)
    foreign = client.post(
        f"/api/v1/camera-search/{context.coreId}/{'0' * 32}/search",
        headers=auth(pair),
        json=_body(),
    )
    assert foreign.status_code == 404
    denied = client.post(
        path,
        headers=auth(pair),
        json=_body(cameraIds=[OTHER_CAMERA]),
    )
    assert denied.status_code == 404

    response = client.post(path, headers=auth(pair), json=_body())
    assert response.status_code == 200
    body = response.json()
    assert len(body["results"]) == 1
    assert body["results"][0]["evidence"]["cameraId"] == CAMERA
    assert body["results"][0]["evidence"]["indexRevision"] == 11
    assert installed.authority.accountId not in response.text
    for forbidden in ("credential", "token", "rawClipUrl", "password"):
        assert forbidden.lower() not in response.text.lower()


def test_route_enforces_closed_bounded_query_and_index_revision(server):
    app, client, _settings, _clock = server
    pair = ready(server)
    _install(app, pair)
    context = app.state.core.context
    path = f"/api/v1/camera-search/{context.coreId}/{context.homeId}/search"
    headers = auth(pair)

    assert client.post(path, headers=headers, json=_body(query="x" * 201)).status_code == 400
    assert client.post(
        path,
        headers=headers,
        json={**_body(), "credential": "synthetic-secret"},
    ).status_code == 400
    drift = client.post(
        path,
        headers=headers,
        json=_body(expectedIndexRevision=12),
    )
    assert drift.status_code == 409
    assert drift.json()["error"]["code"] == "revision_conflict"


def test_late_session_revocation_discards_computed_results(server):
    app, client, _settings, _clock = server
    pair = ready(server)
    holder = {}

    def planner(_query):
        app.state.core.auth.logout(holder["principal"])
        return ["parcel"]

    principal, _installed = _install(app, pair, planner=planner)
    holder["principal"] = principal
    context = app.state.core.context
    response = client.post(
        f"/api/v1/camera-search/{context.coreId}/{context.homeId}/search",
        headers=auth(pair),
        json=_body(),
    )
    assert response.status_code == 401
    assert response.json()["error"]["code"] == "invalid_session"
    assert "results" not in response.text


def test_late_authority_revision_drift_is_a_conflict(server):
    app, client, _settings, _clock = server
    pair = ready(server)
    holder = {}

    def planner(_query):
        installed = holder["installed"]
        installed.current[0] = installed.authority.model_copy(
            update={"memberRevision": installed.authority.memberRevision + 1}
        )
        return ["parcel"]

    _principal, installed = _install(app, pair, planner=planner)
    holder["installed"] = installed
    context = app.state.core.context
    response = client.post(
        f"/api/v1/camera-search/{context.coreId}/{context.homeId}/search",
        headers=auth(pair),
        json=_body(),
    )
    assert response.status_code == 409
    assert response.json()["error"]["code"] == "revision_conflict"
    assert "results" not in response.text
