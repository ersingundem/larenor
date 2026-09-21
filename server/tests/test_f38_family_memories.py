import json
from types import MappingProxyType

import pytest
from larenor_server.family_memories import (
    ImmichMemoryAdapter,
    MemoryError,
    MemoryPolicy,
    MemorySearch,
)
from larenor_server.services.service import ServiceConnection
from larenor_server.services.transport import ProbeResponse

ALBUM = "11111111-1111-4111-8111-111111111111"
OTHER_ALBUM = "22222222-2222-4222-8222-222222222222"
PERSON = "33333333-3333-4333-8333-333333333333"
ASSET = "44444444-4444-4444-8444-444444444444"


class Transport:
    def __init__(self, response):
        self.response = response
        self.calls = []
        self.closed = False

    def request(self, method, path, **kwargs):
        self.calls.append((method, path, kwargs))
        return self.response

    def close(self):
        self.closed = True


def reply(items):
    body = {
        "albums": {"total": 0, "count": 0, "items": [], "facets": []},
        "assets": {
            "total": len(items),
            "count": len(items),
            "items": items,
            "facets": [],
            "nextPage": None,
            "nextCursor": None,
        },
    }
    return ProbeResponse(
        200,
        (("content-type", "application/json; charset=utf-8"),),
        json.dumps(body).encode(),
    )


def asset(**changes):
    return {
        "id": ASSET,
        "type": "IMAGE",
        "originalFileName": "İzmir-2026.jpg",
        "fileCreatedAt": "2026-08-31T19:30:00.000Z",
        "thumbhash": "AQIDBA==",
        "ownerId": "private-owner",
        "originalPath": "/private/family/original.jpg",
        "checksum": "private-checksum",
        **changes,
    }


def policy(*, face=False):
    return MemoryPolicy(
        core_id="a" * 32,
        home_id="b" * 32,
        account_id="c" * 32,
        service_id="d" * 32,
        service_revision=7,
        allowed_album_ids=(ALBUM,),
        face_search_enabled=face,
    )


def connection(*, credentials=None, revision=7):
    return ServiceConnection(
        id="d" * 32,
        name="Private photos",
        kind="immich",
        base_url="https://photos.example.test",
        revision=revision,
        credentials=MappingProxyType(credentials or {"apiKey": "private-api-key"}),
    )


def adapter(transport, *, current_policy=None, current_connection=None):
    return ImmichMemoryAdapter(
        current_connection or connection(),
        current_policy or policy(),
        transport_factory=lambda endpoint, **limits: (
            transport
            if endpoint == "https://photos.example.test"
            and limits == {"max_bytes": 2 * 1024 * 1024}
            else pytest.fail("unexpected transport binding")
        ),
    )


def code(expected):
    return pytest.raises(MemoryError, match=f"^{expected}$")


def test_album_confined_turkish_search_minimizes_returned_metadata():
    transport = Transport(reply([asset()]))
    client = adapter(transport)
    result = client.search(
        MemorySearch(
            "İzmir sahili",
            (ALBUM,),
            limit=12,
            taken_after="2026-01-01T00:00:00Z",
            taken_before="2027-01-01T00:00:00Z",
        )
    )
    assert result.assets[0].file_name == "İzmir-2026.jpg"
    assert not hasattr(result.assets[0], "original_path")
    method, path, kwargs = transport.calls.pop()
    assert (method, path) == ("POST", "/api/search/smart")
    assert kwargs["headers"]["x-api-key"] == "private-api-key"
    assert json.loads(kwargs["body"]) == {
        "filter": {
            "albumIds": {"any": [ALBUM]},
            "takenAt": {
                "gte": "2026-01-01T00:00:00Z",
                "lt": "2027-01-01T00:00:00Z",
            },
            "type": {"eq": "IMAGE"},
        },
        "language": "tr",
        "query": "İzmir sahili",
        "size": 12,
    }


def test_album_and_face_consent_fail_before_network_and_retirement_is_terminal():
    transport = Transport(reply([]))
    client = adapter(transport)
    with code("album_forbidden"):
        client.search(MemorySearch("family", (OTHER_ALBUM,)))
    with code("face_consent_required"):
        client.search(MemorySearch("birthday", (ALBUM,), person_ids=(PERSON,)))
    assert transport.calls == []
    client.close()
    assert transport.closed
    with code("retired"):
        client.search(MemorySearch("family", (ALBUM,)))
    assert transport.calls == []


def test_explicit_face_consent_and_bearer_binding_are_exact():
    transport = Transport(reply([]))
    client = adapter(
        transport,
        current_policy=policy(face=True),
        current_connection=connection(credentials={"token": "private-token"}),
    )
    client.search(MemorySearch("Ada", (ALBUM,), person_ids=(PERSON,)))
    body = json.loads(transport.calls[0][2]["body"])
    assert body["filter"]["personIds"] == {"any": [PERSON]}
    assert transport.calls[0][2]["headers"]["Authorization"] == "Bearer private-token"


@pytest.mark.parametrize(
    "response",
    [
        ProbeResponse(401, (("content-type", "application/json"),), b"{}"),
        ProbeResponse(200, (), b"{}"),
        ProbeResponse(200, (("content-type", "application/json"),), b"not-json"),
        reply([asset(), asset()]),
        reply([asset(type="VIDEO")]),
        reply([asset(thumbhash="not base64")]),
        reply([asset(originalFileName="x" * 513)]),
    ],
)
def test_malformed_or_overbroad_immich_replies_fail_closed(response):
    with code("invalid_response"):
        adapter(Transport(response)).search(MemorySearch("family", (ALBUM,)))


def test_connection_revision_and_credential_shape_cannot_drift():
    for changed in [
        connection(revision=8),
        connection(credentials={"apiKey": "a", "token": "b"}),
        ServiceConnection(
            id="d" * 32,
            name="Wrong",
            kind="jellyfin",
            base_url="https://photos.example.test",
            revision=7,
            credentials=MappingProxyType({"apiKey": "private"}),
        ),
    ]:
        with code("binding_changed"):
            adapter(Transport(reply([])), current_connection=changed)
