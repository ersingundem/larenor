"""Account-scoped Jellyfin latest and resume rows over proved streams."""

import json
import time

import pytest

from larenor_server.plugins.jellyfin_media_rows_runtime import (
    JellyfinMediaRowsProtocol,
    JellyfinMediaRowsRuntimeError,
)
from test_jellyfin_startup import Connection, response


INSTALLATION = "a" * 32
USER = "b" * 32
TOKEN = "c" * 32


def json_response(value, status=200):
    return response(
        status,
        json.dumps(value, separators=(",", ":")).encode(),
        content_type=b"application/json",
        extra=b"Connection: close\r\n",
    )


def item(identifier, name, kind, *, created, runtime=3600, position=0):
    return {
        "Id": identifier,
        "Name": name,
        "Type": kind,
        "DateCreated": created,
        "RunTimeTicks": runtime * 10_000_000,
        "UserData": {"PlaybackPositionTicks": position * 10_000_000},
    }


def test_reads_bounded_account_rows_and_never_serializes_user_identity():
    recent = [
        item("1" * 32, "Arrival", "Movie", created="2026-09-23T20:00:00.0000000Z"),
        item("2" * 32, "Pilot", "Episode", created="2026-09-22T20:00:00Z"),
    ]
    resume = {
        "Items": [item(
            "3" * 32, "Interstellar", "Movie",
            created="2026-09-20T20:00:00Z", runtime=7200, position=1800,
        )],
        "TotalRecordCount": 1,
        "StartIndex": 0,
    }
    connections = (
        Connection([json_response(recent)]),
        Connection([json_response(resume)]),
    )

    result = JellyfinMediaRowsProtocol(revision_seed=100).read(
        connections,
        api_key=TOKEN,
        user_id=USER,
        installation_id=INSTALLATION,
        deadline=time.monotonic() + 2,
    )

    assert result.revision == 100
    assert [item.title for item in result.recent] == ["Arrival", "Pilot"]
    assert result.resume[0].positionSeconds == 1800
    assert result.resume[0].runtimeSeconds == 7200
    assert USER not in repr(result) and TOKEN not in repr(result)
    assert connections[0].requests[0].startswith(b"GET /Items/Latest?")
    assert b"userId=" + USER.encode() in connections[0].requests[0]
    assert connections[1].requests[0].startswith(
        b"GET /Users/" + USER.encode() + b"/Items/Resume?"
    )
    assert all(connection.closed for connection in connections)


def test_revision_changes_only_when_projected_rows_change():
    protocol = JellyfinMediaRowsProtocol(revision_seed=700)

    def read(title):
        latest = [item(
            "1" * 32, title, "Movie", created="2026-09-23T20:00:00Z",
        )]
        return protocol.read(
            (Connection([json_response(latest)]), Connection([json_response({
                "Items": [], "TotalRecordCount": 0, "StartIndex": 0,
            })])),
            api_key=TOKEN,
            user_id=USER,
            installation_id=INSTALLATION,
            deadline=time.monotonic() + 2,
        )

    assert read("Arrival").revision == 700
    assert read("Arrival").revision == 700
    assert read("Arrival 2").revision == 701


@pytest.mark.parametrize("lane,payload", [
    ("recent", [item(
        "1" * 32, "A", "Series", created="2026-09-23T20:00:00Z",
    )]),
    ("recent", [item(
        "1" * 32, "A", "Movie", created="2026-09-23T20:00:00Z",
    )] * 25),
    ("resume", {"Items": [item(
        "1" * 32, "A", "Movie", created="2026-09-23T20:00:00Z",
        position=3600,
    )], "TotalRecordCount": 1, "StartIndex": 1}),
    ("resume", {"Items": [item(
        "1" * 32, "A", "Movie", created="2026-09-23T20:00:00Z",
        runtime=100, position=101,
    )], "TotalRecordCount": 1, "StartIndex": 0}),
])
def test_malformed_or_unbounded_rows_fail_closed(lane, payload):
    empty_recent = []
    empty_resume = {"Items": [], "TotalRecordCount": 0, "StartIndex": 0}
    values = (
        payload if lane == "recent" else empty_recent,
        payload if lane == "resume" else empty_resume,
    )
    with pytest.raises(
        JellyfinMediaRowsRuntimeError,
        match="^jellyfin_media_rows_readback_changed$",
    ):
        JellyfinMediaRowsProtocol().read(
            tuple(Connection([json_response(value)]) for value in values),
            api_key=TOKEN,
            user_id=USER,
            installation_id=INSTALLATION,
            deadline=time.monotonic() + 2,
        )


@pytest.mark.parametrize("change", ["connections", "token", "user", "installation"])
def test_invalid_inputs_open_no_stream(change):
    connections = (Connection([]), Connection([]))
    values = {
        "connections": connections,
        "api_key": TOKEN,
        "user_id": USER,
        "installation_id": INSTALLATION,
        "deadline": time.monotonic() + 2,
    }
    values[{
        "connections": "connections",
        "token": "api_key",
        "user": "user_id",
        "installation": "installation_id",
    }[change]] = {
        "connections": (connections[0],),
        "token": "secret",
        "user": "bad",
        "installation": "bad",
    }[change]
    with pytest.raises(
        JellyfinMediaRowsRuntimeError,
        match="^invalid_jellyfin_media_rows_request$",
    ):
        JellyfinMediaRowsProtocol().read(**values)
    assert all(connection.requests == [] for connection in connections)
