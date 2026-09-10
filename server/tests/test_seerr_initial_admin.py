"""Private Seerr initial-admin session and API-key bootstrap."""

import base64
import json

import pytest

from larenor_server.plugins.seerr_initial_admin import (
    SeerrInitialAdmin,
    SeerrInitialAdminError,
)
from test_jellyfin_startup import Connection


USERNAME = "larenor-system"
JELLYFIN_HOST = "larenor-" + "6" * 32
PASSWORD = "S" * 48
COOKIE = "s%3A" + "A" * 48 + "." + "b" * 43
DECODED_KEY = b"178900000000012345678-1234-4abc-8def-123456789abc"
API_KEY = base64.b64encode(DECODED_KEY).decode("ascii")


def response(value, status=200, *, cookie=None, close=False):
    body = json.dumps(value, separators=(",", ":")).encode("utf-8")
    headers = [
        f"HTTP/1.1 {status} status".encode("ascii"),
        b"Content-Type: application/json",
        f"Content-Length: {len(body)}".encode("ascii"),
        b"Connection: close" if close else b"Connection: keep-alive",
    ]
    if cookie is not None:
        headers.append(
            ("Set-Cookie: connect.sid=" + cookie
             + "; Path=/; Expires=Fri, 10 Oct 2026 12:00:00 GMT; "
               "HttpOnly; SameSite=Lax").encode("ascii")
        )
    return b"\r\n".join(headers) + b"\r\n\r\n" + body


def request(raw):
    head, body = raw.split(b"\r\n\r\n", 1)
    return head.split(b"\r\n"), json.loads(body) if body else None


def valid_responses():
    return [
        response({"initialized": False, "applicationTitle": "Seerr"}),
        response({
            "id": 1,
            "permissions": 2,
            "userType": 3,
            "jellyfinUsername": USERNAME,
        }, cookie=COOKIE),
        response({"apiKey": API_KEY, "mediaServerType": 2}),
        response({"status": "ok"}, close=True),
    ]


def test_creates_initial_admin_reads_key_and_destroys_session():
    connection = Connection(valid_responses())

    result = SeerrInitialAdmin().create(
        connection, username=USERNAME, credential=PASSWORD,
        jellyfin_hostname=JELLYFIN_HOST,
    )

    assert result.state == "verified"
    assert result.api_key == API_KEY
    assert result.completed_steps == (
        "uninitialized_verified", "admin_created", "api_key_verified",
        "session_destroyed",
    )
    lines = [request(raw)[0][0] for raw in connection.requests]
    assert lines == [
        b"GET /api/v1/settings/public HTTP/1.1",
        b"POST /api/v1/auth/jellyfin HTTP/1.1",
        b"GET /api/v1/settings/main HTTP/1.1",
        b"POST /api/v1/auth/logout HTTP/1.1",
    ]
    auth_headers, auth_body = request(connection.requests[1])
    assert auth_body == {
        "email": USERNAME,
        "hostname": JELLYFIN_HOST,
        "password": PASSWORD,
        "port": 8096,
        "serverType": 2,
        "urlBase": "",
        "useSsl": False,
        "username": USERNAME,
    }
    assert all(b"Cookie:" not in line for line in auth_headers)
    for raw in connection.requests[2:]:
        assert b"Cookie: connect.sid=" + COOKIE.encode("ascii") in raw
    assert connection.closed
    assert PASSWORD not in repr(result) and COOKIE not in repr(result)


@pytest.mark.parametrize("public", [
    {"initialized": True, "applicationTitle": "Seerr"},
    {"initialized": False, "applicationTitle": "Foreign"},
    {"initialized": 0, "applicationTitle": "Seerr"},
    {"initialized": False, "applicationTitle": "Seerr", "unknown": True},
])
def test_only_exact_fresh_seerr_instance_can_receive_credentials(public):
    connection = Connection([response(public, close=True)])

    with pytest.raises(
        SeerrInitialAdminError, match="^seerr_initial_state_conflict$"
    ) as raised:
        SeerrInitialAdmin().create(
            connection, username=USERNAME, credential=PASSWORD,
        jellyfin_hostname=JELLYFIN_HOST,
        )

    assert not raised.value.uncertain_effect
    assert len(connection.requests) == 1 and connection.closed


@pytest.mark.parametrize("user", [
    {"id": 2, "permissions": 2, "userType": 3,
     "jellyfinUsername": USERNAME},
    {"id": 1, "permissions": 32, "userType": 3,
     "jellyfinUsername": USERNAME},
    {"id": 1, "permissions": 2, "userType": 1,
     "jellyfinUsername": USERNAME},
    {"id": 1, "permissions": 2, "userType": 3,
     "jellyfinUsername": "foreign"},
])
def test_auth_response_must_be_exact_larenor_jellyfin_admin(user):
    connection = Connection([
        response({"initialized": False, "applicationTitle": "Seerr"}),
        response(user, cookie=COOKIE),
    ])

    with pytest.raises(
        SeerrInitialAdminError, match="^seerr_initial_admin_conflict$"
    ) as raised:
        SeerrInitialAdmin().create(
            connection, username=USERNAME, credential=PASSWORD,
        jellyfin_hostname=JELLYFIN_HOST,
        )

    assert raised.value.uncertain_effect
    assert raised.value.completed_steps == ("uninitialized_verified",)
    assert connection.closed


@pytest.mark.parametrize("cookie", [
    None,
    "short",
    "s%3A" + "A" * 48 + "." + "b" * 43 + "; Domain=attacker.test",
])
def test_missing_or_untrusted_session_cookie_never_reaches_settings(cookie):
    connection = Connection([
        response({"initialized": False, "applicationTitle": "Seerr"}),
        response({
            "id": 1, "permissions": 2, "userType": 3,
            "jellyfinUsername": USERNAME,
        }, cookie=cookie),
    ])

    with pytest.raises(
        SeerrInitialAdminError, match="^seerr_session_protocol$"
    ) as raised:
        SeerrInitialAdmin().create(
            connection, username=USERNAME, credential=PASSWORD,
        jellyfin_hostname=JELLYFIN_HOST,
        )

    assert raised.value.uncertain_effect
    assert len(connection.requests) == 2 and connection.closed


@pytest.mark.parametrize("key", [
    "",
    "not-base64",
    base64.b64encode(b"wrong-format").decode("ascii"),
    base64.b64encode(DECODED_KEY + b"extra").decode("ascii"),
])
def test_generated_api_key_must_match_pinned_seerr_contract(key):
    replies = valid_responses()
    replies[2] = response({"apiKey": key, "mediaServerType": 2}, close=True)
    connection = Connection(replies[:3])

    with pytest.raises(
        SeerrInitialAdminError, match="^seerr_api_key_protocol$"
    ) as raised:
        SeerrInitialAdmin().create(
            connection, username=USERNAME, credential=PASSWORD,
        jellyfin_hostname=JELLYFIN_HOST,
        )

    assert raised.value.uncertain_effect
    assert raised.value.completed_steps == (
        "uninitialized_verified", "admin_created",
    )
    if key:
        assert key not in repr(raised.value)


@pytest.mark.parametrize(("username", "credential"), [
    ("admin", PASSWORD),
    (USERNAME, "short"),
    (USERNAME, "x" * 129),
])
def test_untrusted_inputs_send_nothing(username, credential):
    connection = Connection([])

    with pytest.raises(
        SeerrInitialAdminError, match="^invalid_seerr_initial_admin$"
    ):
        SeerrInitialAdmin().create(
            connection, username=username, credential=credential,
        )

    assert connection.requests == []


def test_authentication_failure_is_secret_free_and_not_marked_uncertain():
    connection = Connection([
        response({"initialized": False, "applicationTitle": "Seerr"}),
        response({"message": PASSWORD}, status=403, close=True),
    ])

    with pytest.raises(
        SeerrInitialAdminError, match="^seerr_jellyfin_authentication_failed$"
    ) as raised:
        SeerrInitialAdmin().create(
            connection, username=USERNAME, credential=PASSWORD,
        jellyfin_hostname=JELLYFIN_HOST,
        )

    assert not raised.value.uncertain_effect
    assert PASSWORD not in str(raised.value) + repr(raised.value)
    assert connection.closed

@pytest.mark.parametrize("hostname", [
    "jellyfin",
    "larenor-jellyfin",
    "larenor-" + "6" * 31,
    "larenor-" + "G" * 32,
])
def test_untrusted_jellyfin_hostname_sends_nothing(hostname):
    connection = Connection([])

    with pytest.raises(
        SeerrInitialAdminError, match="^invalid_seerr_initial_admin$"
    ):
        SeerrInitialAdmin().create(
            connection, username=USERNAME, credential=PASSWORD,
            jellyfin_hostname=hostname,
        )

    assert connection.requests == []
