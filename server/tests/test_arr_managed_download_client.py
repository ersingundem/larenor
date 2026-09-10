"""Idempotent Arr to qBittorrent download-client wiring."""

import json

import pytest

from larenor_server.plugins.arr_managed_download_client import (
    ArrManagedDownloadClient,
    ArrManagedDownloadClientError,
)
from test_jellyfin_startup import Connection, response

ARR_KEY = "a" * 32
QBIT_KEY = "qbt_" + "A" * 28


def json_response(value, status=200, *, close=False):
    extra = b"Connection: close\r\n" if close else b"Connection: keep-alive\r\n"
    return response(
        status,
        json.dumps(value, separators=(",", ":")).encode(),
        content_type=b"application/json",
        extra=extra,
    )


def schema(service):
    category = "tvCategory" if service == "sonarr" else "movieCategory"
    recent = "recentTvPriority" if service == "sonarr" else "recentMoviePriority"
    older = "olderTvPriority" if service == "sonarr" else "olderMoviePriority"
    names = [
        "host", "port", "useSsl", "urlBase", "apiKey", "username",
        "password", category, category.replace("Category", "ImportedCategory"),
        recent, older, "initialState", "sequentialOrder", "firstAndLast",
        "contentLayout",
    ]
    return [{
        "implementation": "QBittorrent",
        "configContract": "QBittorrentSettings",
        "protocol": "torrent",
        "fields": [{"name": name, "value": None} for name in names],
    }]


def desired(service, *, masked=False):
    category_field = "tvCategory" if service == "sonarr" else "movieCategory"
    category = "tv" if service == "sonarr" else "movies"
    recent = "recentTvPriority" if service == "sonarr" else "recentMoviePriority"
    older = "olderTvPriority" if service == "sonarr" else "olderMoviePriority"
    values = {
        "host": "qbittorrent", "port": 8080, "useSsl": False,
        "urlBase": "", "apiKey": "********" if masked else QBIT_KEY,
        "username": "", "password": "", category_field: category,
        category_field.replace("Category", "ImportedCategory"): "",
        recent: 0, older: 0, "initialState": 0, "sequentialOrder": False,
        "firstAndLast": False, "contentLayout": 0,
    }
    return {
        "id": 7,
        "name": "Larenor qBittorrent",
        "implementation": "QBittorrent",
        "configContract": "QBittorrentSettings",
        "enable": True,
        "protocol": "torrent",
        "priority": 1,
        "removeCompletedDownloads": True,
        "removeFailedDownloads": True,
        "tags": [],
        "fields": [{"name": key, "value": value} for key, value in values.items()],
    }


def request_parts(raw):
    head, body = raw.split(b"\r\n\r\n", 1)
    return head.split(b"\r\n"), body


@pytest.mark.parametrize("service", ["sonarr", "radarr"])
def test_tests_creates_and_verifies_fixed_download_client(service):
    created = desired(service)
    connection = Connection([
        json_response([]),
        json_response(schema(service)),
        json_response({}),
        json_response(created, status=201),
        json_response([desired(service, masked=True)], close=True),
    ])

    result = ArrManagedDownloadClient().apply(
        connection, service_id=service, arr_api_key=ARR_KEY,
        qbittorrent_api_key=QBIT_KEY,
    )

    assert result.state == "verified"
    assert result.service_id == service
    assert result.client_id == 7
    assert result.category == ("tv" if service == "sonarr" else "movies")
    assert result.completed_steps == (
        "download_clients_observed", "schema_verified", "connection_tested",
        "download_client_created", "download_client_verified",
    )
    assert [request_parts(raw)[0][0] for raw in connection.requests] == [
        b"GET /api/v3/downloadclient HTTP/1.1",
        b"GET /api/v3/downloadclient/schema HTTP/1.1",
        b"POST /api/v3/downloadclient/test HTTP/1.1",
        b"POST /api/v3/downloadclient HTTP/1.1",
        b"GET /api/v3/downloadclient HTTP/1.1",
    ]
    test_body = json.loads(request_parts(connection.requests[2])[1])
    create_body = json.loads(request_parts(connection.requests[3])[1])
    assert test_body == create_body
    fields = {item["name"]: item["value"] for item in create_body["fields"]}
    assert fields["host"] == "qbittorrent"
    assert fields["apiKey"] == QBIT_KEY
    assert fields["tvCategory" if service == "sonarr" else "movieCategory"] == (
        "tv" if service == "sonarr" else "movies"
    )
    assert all(b"X-Api-Key: " + ARR_KEY.encode() in request_parts(raw)[0]
               for raw in connection.requests)
    assert connection.closed and QBIT_KEY not in repr(result)


@pytest.mark.parametrize("service", ["sonarr", "radarr"])
def test_exact_existing_client_is_tested_and_verified_without_create(service):
    connection = Connection([
        json_response([desired(service, masked=True)]),
        json_response(schema(service)),
        json_response({}),
        json_response([desired(service, masked=True)], close=True),
    ])

    result = ArrManagedDownloadClient().apply(
        connection, service_id=service, arr_api_key=ARR_KEY,
        qbittorrent_api_key=QBIT_KEY,
    )

    assert result.completed_steps == (
        "download_clients_observed", "schema_verified", "connection_tested",
        "download_client_verified",
    )
    assert all(b"POST /api/v3/downloadclient HTTP/1.1" not in raw
               for raw in connection.requests)


@pytest.mark.parametrize("existing", [
    [{"id": 2, "name": "Foreign", "implementation": "Transmission"}],
    [desired("sonarr", masked=True), desired("sonarr", masked=True)],
    [{**desired("sonarr", masked=True), "enable": False}],
])
def test_foreign_ambiguous_or_changed_existing_client_never_mutates(existing):
    connection = Connection([json_response(existing)])
    with pytest.raises(
        ArrManagedDownloadClientError, match="^arr_download_client_conflict$"
    ) as raised:
        ArrManagedDownloadClient().apply(
            connection, service_id="sonarr", arr_api_key=ARR_KEY,
            qbittorrent_api_key=QBIT_KEY,
        )
    assert raised.value.completed_steps == ("download_clients_observed",)
    assert not raised.value.uncertain_effect
    assert len(connection.requests) == 1 and connection.closed


@pytest.mark.parametrize("schema_value", [
    [],
    schema("sonarr") + schema("sonarr"),
    [{**schema("sonarr")[0], "implementation": "Transmission"}],
    [{**schema("sonarr")[0], "fields": [{"name": "host", "value": None}]}],
])
def test_schema_must_select_one_exact_pinned_qbittorrent_contract(schema_value):
    connection = Connection([json_response([]), json_response(schema_value)])
    with pytest.raises(
        ArrManagedDownloadClientError, match="^arr_download_client_schema_conflict$"
    ):
        ArrManagedDownloadClient().apply(
            connection, service_id="sonarr", arr_api_key=ARR_KEY,
            qbittorrent_api_key=QBIT_KEY,
        )
    assert len(connection.requests) == 2 and connection.closed


def test_failed_connection_test_never_creates_and_does_not_leak_secret():
    connection = Connection([
        json_response([]), json_response(schema("sonarr")),
        json_response({"message": QBIT_KEY}, status=400, close=True),
    ])
    with pytest.raises(
        ArrManagedDownloadClientError, match="^arr_download_client_test_failed$"
    ) as raised:
        ArrManagedDownloadClient().apply(
            connection, service_id="sonarr", arr_api_key=ARR_KEY,
            qbittorrent_api_key=QBIT_KEY,
        )
    assert not raised.value.uncertain_effect
    assert QBIT_KEY not in str(raised.value) + repr(raised.value)
    assert len(connection.requests) == 3 and connection.closed


def test_connection_loss_after_create_is_uncertain_and_secret_free():
    connection = Connection([
        json_response([]), json_response(schema("sonarr")), json_response({}),
        json_response(desired("sonarr"), status=201),
    ])
    with pytest.raises(
        ArrManagedDownloadClientError, match="^arr_download_client_unavailable$"
    ) as raised:
        ArrManagedDownloadClient().apply(
            connection, service_id="sonarr", arr_api_key=ARR_KEY,
            qbittorrent_api_key=QBIT_KEY,
        )
    assert raised.value.uncertain_effect
    assert raised.value.completed_steps[-1] == "download_client_created"
    assert QBIT_KEY not in str(raised.value) + repr(raised.value)


@pytest.mark.parametrize(("service", "arr_key", "qbit_key"), [
    ("lidarr", ARR_KEY, QBIT_KEY),
    ("Sonarr", ARR_KEY, QBIT_KEY),
    ("sonarr", "bad", QBIT_KEY),
    ("sonarr", ARR_KEY, "bad"),
])
def test_untrusted_inputs_do_not_open_or_mutate(service, arr_key, qbit_key):
    connection = Connection([])
    with pytest.raises(
        ArrManagedDownloadClientError, match="^invalid_arr_managed_download_client$"
    ):
        ArrManagedDownloadClient().apply(
            connection, service_id=service, arr_api_key=arr_key,
            qbittorrent_api_key=qbit_key,
        )
    assert connection.requests == []


@pytest.mark.parametrize(("responses", "code", "uncertain"), [
    ([json_response({}, status=401, close=True)],
     "arr_download_client_authentication_failed", False),
    ([response(200, b'[{"id":1,"id":2}]', content_type=b"application/json")],
     "arr_download_client_observation_payload", False),
    ([json_response([]), json_response(schema("sonarr"), close=True)],
     "arr_download_client_schema_protocol", False),
    ([json_response([]), json_response(schema("sonarr")),
      json_response({}, status=403, close=True)],
     "arr_download_client_authentication_failed", False),
    ([json_response([]), json_response(schema("sonarr")), json_response({}),
      json_response({}, status=500, close=True)],
     "arr_download_client_create_protocol", True),
    ([json_response([]), json_response(schema("sonarr")), json_response({}),
      json_response(desired("sonarr"), status=201),
      json_response([{**desired("sonarr", masked=True), "priority": 2}], close=True)],
     "arr_download_client_conflict", True),
])
def test_protocol_and_auth_failures_are_bounded(responses, code, uncertain):
    connection = Connection(responses)
    with pytest.raises(ArrManagedDownloadClientError, match=f"^{code}$") as raised:
        ArrManagedDownloadClient().apply(
            connection, service_id="sonarr", arr_api_key=ARR_KEY,
            qbittorrent_api_key=QBIT_KEY,
        )
    assert raised.value.uncertain_effect is uncertain
    assert QBIT_KEY not in str(raised.value) + repr(raised.value)
    assert connection.closed


def test_duplicate_or_unknown_schema_fields_are_rejected_without_secret_test():
    duplicate = schema("sonarr")
    duplicate[0]["fields"].append({"name": "host", "value": "attacker"})
    unknown = schema("sonarr")
    unknown[0]["fields"].append({"name": "script", "value": "attacker"})
    for value in (duplicate, unknown):
        connection = Connection([json_response([]), json_response(value)])
        with pytest.raises(
            ArrManagedDownloadClientError,
            match="^arr_download_client_schema_conflict$",
        ):
            ArrManagedDownloadClient().apply(
                connection, service_id="sonarr", arr_api_key=ARR_KEY,
                qbittorrent_api_key=QBIT_KEY,
            )
        assert len(connection.requests) == 2 and connection.closed
