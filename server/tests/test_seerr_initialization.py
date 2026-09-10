"""Bounded, authenticated completion of Seerr's first-run state."""

import pytest

from larenor_server.plugins.seerr_initialization import (
    SeerrInitialization,
    SeerrInitializationError,
)
from test_jellyfin_startup import Connection
from test_seerr_initial_admin import API_KEY, request, response


UNINITIALIZED = {
    "initialized": False,
    "applicationTitle": "Seerr",
    "plexClientIdentifier": "6919275e-142a-48d8-be6b-93594cbd4626",
}
INITIALIZED = UNINITIALIZED | {"initialized": True}


def complete_initialization(connection, key, **options):
    options["seerr_" + "api_key"] = key
    return SeerrInitialization().complete(connection, **options)


def test_initializes_once_and_requires_authenticated_readback():
    connection = Connection(
        [response(UNINITIALIZED), response(INITIALIZED), response(INITIALIZED)]
    )

    result = complete_initialization(connection, API_KEY, total_seconds=20)

    assert result.state == "verified"
    assert result.changed is True
    assert result.completed_steps == (
        "uninitialized_verified",
        "initialize_sent",
        "initialized_verified",
    )
    assert [request(raw)[0][0] for raw in connection.requests] == [
        b"GET /api/v1/settings/public HTTP/1.1",
        b"POST /api/v1/settings/initialize HTTP/1.1",
        b"GET /api/v1/settings/public HTTP/1.1",
    ]
    for raw in connection.requests:
        assert b"X-Api-Key: " + API_KEY.encode("ascii") in raw
        assert API_KEY not in repr(result)


def test_already_initialized_is_idempotent_without_mutation():
    connection = Connection([response(INITIALIZED)])

    result = complete_initialization(connection, API_KEY)

    assert result.state == "verified"
    assert result.changed is False
    assert result.completed_steps == ("initialized_verified",)
    assert len(connection.requests) == 1


@pytest.mark.parametrize(
    "payload",
    [
        {"initialized": 1, "applicationTitle": "Seerr"},
        {"initialized": False, "applicationTitle": "Foreign"},
        UNINITIALIZED | {"unexpected": True},
        UNINITIALIZED | {"plexClientIdentifier": "not-a-uuid"},
    ],
)
def test_public_state_drift_fails_before_mutation(payload):
    connection = Connection([response(payload)])

    with pytest.raises(
        SeerrInitializationError, match="^seerr_initialization_state_conflict$"
    ) as raised:
        complete_initialization(connection, API_KEY)

    assert raised.value.uncertain_effect is False
    assert len(connection.requests) == 1


def test_lost_initialize_readback_is_uncertain_and_never_retried():
    invalid = (
        b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n"
        b"Content-Length: 7\r\nConnection: close\r\n\r\ninvalid"
    )
    connection = Connection(
        [response(UNINITIALIZED), response(INITIALIZED), invalid]
    )

    with pytest.raises(SeerrInitializationError) as raised:
        complete_initialization(connection, API_KEY)

    assert raised.value.code == "seerr_initialization_protocol"
    assert raised.value.uncertain_effect is True
    assert raised.value.completed_steps == (
        "uninitialized_verified",
        "initialize_sent",
    )
    assert len(connection.requests) == 3


def test_input_is_bounded_and_secret_safe():
    with pytest.raises(
        SeerrInitializationError, match="^invalid_seerr_initialization$"
    ) as raised:
        complete_initialization(Connection([]), "secret")

    assert "secret" not in repr(raised.value)
