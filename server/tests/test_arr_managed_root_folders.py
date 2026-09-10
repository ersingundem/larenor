"""Idempotent Sonarr/Radarr root-folder wiring over a proved stream."""

import json

import pytest

from larenor_server.plugins.arr_managed_root_folders import (
    ArrManagedRootFolders,
    ArrManagedRootFoldersError,
)
from test_arr_owned_config import API_KEY
from test_jellyfin_startup import Connection, response


def json_response(value, status=200, *, close=False):
    extra = b"Connection: close\r\n" if close else b"Connection: keep-alive\r\n"
    return response(
        status,
        json.dumps(value, separators=(",", ":")).encode(),
        content_type=b"application/json",
        extra=extra,
    )


def parts(raw):
    head, body = raw.split(b"\r\n\r\n", 1)
    return head.split(b"\r\n"), body


@pytest.mark.parametrize(
    ("service", "path"),
    [("sonarr", "/data/shows"), ("radarr", "/data/movies")],
)
def test_creates_fixed_root_then_requires_exact_readback(service, path):
    connection = Connection(
        [
            json_response([]),
            json_response({"id": 7, "path": path}, status=201),
            json_response([{"id": 7, "path": path}], close=True),
        ]
    )

    result = ArrManagedRootFolders().apply(
        connection, service_id=service, api_key=API_KEY
    )

    assert result.state == "verified"
    assert result.service_id == service
    assert result.path == path
    assert result.completed_steps == (
        "root_folders_observed",
        "root_folder_created",
        "root_folder_verified",
    )
    assert [parts(raw)[0][0] for raw in connection.requests] == [
        b"GET /api/v3/rootfolder HTTP/1.1",
        b"POST /api/v3/rootfolder HTTP/1.1",
        b"GET /api/v3/rootfolder HTTP/1.1",
    ]
    assert json.loads(parts(connection.requests[1])[1]) == {"path": path}
    assert all(
        b"X-Api-Key: " + API_KEY.encode() in parts(raw)[0]
        for raw in connection.requests
    )
    assert connection.closed and API_KEY not in repr(result)


@pytest.mark.parametrize(
    ("service", "path"),
    [("sonarr", "/data/shows"), ("radarr", "/data/movies")],
)
def test_exact_existing_root_is_verified_without_mutation(service, path):
    connection = Connection([json_response([{"id": 9, "path": path}])])

    result = ArrManagedRootFolders().apply(
        connection, service_id=service, api_key=API_KEY
    )

    assert result.completed_steps == (
        "root_folders_observed",
        "root_folder_verified",
    )
    assert len(connection.requests) == 1 and connection.closed


@pytest.mark.parametrize(
    "observed",
    [
        [{"id": 1, "path": "/data/other"}],
        [{"id": 1, "path": "/data/shows"}, {"id": 2, "path": "/data/other"}],
        [{"id": 0, "path": "/data/shows"}],
        [{"id": True, "path": "/data/shows"}],
        [{"id": 1}],
        {"id": 1, "path": "/data/shows"},
    ],
)
def test_conflicting_or_malformed_existing_state_never_mutates(observed):
    connection = Connection([json_response(observed)])

    with pytest.raises(
        ArrManagedRootFoldersError, match="^arr_root_folder_conflict$"
    ) as raised:
        ArrManagedRootFolders().apply(connection, service_id="sonarr", api_key=API_KEY)

    assert raised.value.completed_steps == ("root_folders_observed",)
    assert not raised.value.uncertain_effect
    assert len(connection.requests) == 1 and connection.closed


def test_connection_loss_after_create_reports_uncertain_effect_without_secret():
    connection = Connection(
        [json_response([]), json_response({"id": 7, "path": "/data/shows"}, 201)]
    )

    with pytest.raises(
        ArrManagedRootFoldersError, match="^arr_root_folders_unavailable$"
    ) as raised:
        ArrManagedRootFolders().apply(connection, service_id="sonarr", api_key=API_KEY)

    assert raised.value.completed_steps == (
        "root_folders_observed",
        "root_folder_created",
    )
    assert raised.value.uncertain_effect
    assert API_KEY not in str(raised.value) + repr(raised.value)


@pytest.mark.parametrize("status", [401, 403])
def test_api_key_auth_failure_is_closed_and_never_retried(status):
    connection = Connection(
        [json_response({"private": API_KEY}, status=status, close=True)]
    )
    with pytest.raises(
        ArrManagedRootFoldersError,
        match="^arr_root_folders_authentication_failed$",
    ):
        ArrManagedRootFolders().apply(connection, service_id="sonarr", api_key=API_KEY)
    assert len(connection.requests) == 1 and connection.closed


def test_plain_text_auth_failure_after_create_is_uncertain_and_secret_free():
    connection = Connection(
        [
            json_response([]),
            response(403, b"Forbidden", content_type=b"text/plain"),
        ]
    )
    with pytest.raises(
        ArrManagedRootFoldersError,
        match="^arr_root_folders_authentication_failed$",
    ) as raised:
        ArrManagedRootFolders().apply(connection, service_id="sonarr", api_key=API_KEY)
    assert raised.value.completed_steps == ("root_folders_observed",)
    assert raised.value.uncertain_effect
    assert API_KEY not in str(raised.value) + repr(raised.value)


@pytest.mark.parametrize(
    ("responses", "code"),
    [
        (
            [response(200, b"not-json", content_type=b"application/json")],
            "arr_root_folders_observation_payload",
        ),
        ([json_response([], status=500)], "arr_root_folders_observation_http"),
        ([json_response([], close=True)], "arr_root_folders_observation_closed"),
        (
            [
                b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n"
                b"Content-Length: nope\r\n\r\n"
            ],
            "arr_root_folders_observation_framing",
        ),
        (
            [json_response([]), json_response({}, status=409)],
            "arr_root_folder_create_protocol",
        ),
        (
            [
                json_response([]),
                json_response({"id": 7, "path": "/data/shows"}, status=201),
                response(200, b"not-json", content_type=b"application/json"),
            ],
            "arr_root_folders_verification_protocol",
        ),
    ],
)
def test_failures_have_bounded_stage_codes(responses, code):
    connection = Connection(responses)
    with pytest.raises(ArrManagedRootFoldersError, match=f"^{code}$") as raised:
        ArrManagedRootFolders().apply(connection, service_id="sonarr", api_key=API_KEY)
    assert raised.value.uncertain_effect is (len(responses) > 1)
    assert connection.closed


@pytest.mark.parametrize(
    ("service", "api_key"),
    [("lidarr", API_KEY), ("Sonarr", API_KEY), ("sonarr", "bad")],
)
def test_untrusted_inputs_do_not_open_or_mutate(service, api_key):
    connection = Connection([])
    with pytest.raises(
        ArrManagedRootFoldersError, match="^invalid_arr_managed_root_folders$"
    ):
        ArrManagedRootFolders().apply(connection, service_id=service, api_key=api_key)
    assert connection.requests == []
