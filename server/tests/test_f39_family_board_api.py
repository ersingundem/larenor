from conftest import auth, ready


def _card(identity="8" * 32, text="Movie night"):
    return {
        "schemaVersion": 1,
        "id": identity,
        "kind": "card",
        "text": text,
        "x": 24.0,
        "y": 24.0,
        "color": "yellow",
    }


def _expectations(authority):
    return {
        "expectedHomeRevision": authority["homeRevision"],
        "expectedAccountRevision": authority["accountRevision"],
        "expectedMemberRevision": authority["memberRevision"],
        "expectedSessionFamilyId": authority["sessionFamilyId"],
    }


def test_authenticated_authority_empty_snapshot_and_exact_command(server):
    app, client, _settings, _clock = server
    pair = ready(server)
    scope = app.state.core.context
    root = f"/api/v1/family-boards/{scope.coreId}/{scope.homeId}"

    authority_response = client.get(root + "/authority", headers=auth(pair))
    assert authority_response.status_code == 200
    authority = authority_response.json()
    assert authority == {
        "schemaVersion": 1,
        "coreId": scope.coreId,
        "homeId": scope.homeId,
        "homeRevision": 1,
        "boardId": authority["boardId"],
        "accountId": authority["accountId"],
        "accountRevision": 2,
        "memberRevision": 2,
        "sessionFamilyId": authority["sessionFamilyId"],
        "role": "admin",
        "canRead": True,
        "canWrite": True,
        "active": True,
    }
    board = root + "/" + authority["boardId"]
    empty = client.get(board, headers=auth(pair))
    assert empty.status_code == 200
    assert empty.json()["boardRevision"] == 0
    assert empty.json()["elements"] == []
    empty_delta = client.post(
        board + "/delta",
        headers=auth(pair),
        json={
            "schemaVersion": 1,
            "afterSequence": 0,
            "limit": 100,
            **_expectations(authority),
        },
    )
    assert empty_delta.status_code == 200
    assert empty_delta.json()["boardRevision"] == 0
    assert empty_delta.json()["events"] == []

    body = {
        "schemaVersion": 1,
        "requestId": "9" * 32,
        "expectedBoardRevision": 0,
        "action": "append",
        "element": _card(),
        "elementId": None,
        **_expectations(authority),
    }
    receipt = client.post(board + "/commands", headers=auth(pair), json=body)
    assert receipt.status_code == 200
    assert receipt.json()["boardRevision"] == 1
    readback = client.get(board, headers=auth(pair)).json()
    assert readback["elements"] == [_card()]


def test_delta_is_bounded_and_session_revision_drift_fails_closed(server):
    app, client, _settings, _clock = server
    first = ready(server)
    scope = app.state.core.context
    root = f"/api/v1/family-boards/{scope.coreId}/{scope.homeId}"
    authority = client.get(root + "/authority", headers=auth(first)).json()
    board = root + "/" + authority["boardId"]
    command = {
        "schemaVersion": 1,
        "requestId": "9" * 32,
        "expectedBoardRevision": 0,
        "action": "append",
        "element": _card(),
        "elementId": None,
        **_expectations(authority),
    }
    assert (
        client.post(board + "/commands", headers=auth(first), json=command).status_code
        == 200
    )

    delta = client.post(
        board + "/delta",
        headers=auth(first),
        json={
            "schemaVersion": 1,
            "afterSequence": 0,
            "limit": 100,
            **_expectations(authority),
        },
    )
    assert delta.status_code == 200
    assert delta.json()["nextAfter"] == 1
    assert len(delta.json()["events"]) == 1

    # A second login is a different session family. It may read the shared
    # board, but cannot replay the first family's retained authority.
    second_login = client.post(
        "/api/v1/auth/login",
        json={
            "username": "admin",
            "password": "Synthetic new password 2026",
            "deviceName": "Second tablet",
        },
    ).json()
    conflict = client.post(
        board + "/delta",
        headers=auth(second_login),
        json={
            "schemaVersion": 1,
            "afterSequence": 0,
            "limit": 100,
            **_expectations(authority),
        },
    )
    assert conflict.status_code == 409
    assert conflict.json()["error"]["code"] == "revision_conflict"
    oversized = client.post(
        board + "/delta",
        headers=auth(first),
        json={
            "schemaVersion": 1,
            "afterSequence": 0,
            "limit": 101,
            **_expectations(authority),
        },
    )
    assert oversized.status_code == 400


def test_wrong_home_and_unauthenticated_requests_disclose_no_board(server):
    app, client, _settings, _clock = server
    pair = ready(server)
    scope = app.state.core.context
    root = f"/api/v1/family-boards/{scope.coreId}/{scope.homeId}"
    authority = client.get(root + "/authority", headers=auth(pair)).json()
    board = root + "/" + authority["boardId"]

    assert client.get(board).status_code == 401
    wrong = client.get(
        f"/api/v1/family-boards/{scope.coreId}/{'f' * 32}/authority",
        headers=auth(pair),
    )
    assert wrong.status_code == 404
    assert wrong.json()["error"]["code"] == "not_found"
    assert "Movie night" not in str(wrong.json())
