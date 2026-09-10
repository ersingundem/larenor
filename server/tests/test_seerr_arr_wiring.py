"""Bounded Seerr-to-Arr service wiring on one proved private stream."""

import json

import pytest

from larenor_server.plugins.seerr_arr_wiring import (
    SeerrArrService,
    SeerrArrWiring,
    SeerrArrWiringError,
)
from test_jellyfin_startup import Connection
from test_seerr_initial_admin import API_KEY, request, response


ARR_KEY = "a" * 32
RADARR = SeerrArrService(
    "radarr", "larenor-" + "1" * 32, 7878, ARR_KEY, 4, "HD-1080p", "/media/movies"
)
SONARR = SeerrArrService(
    "sonarr", "larenor-" + "2" * 32, 8989, "b" * 32, 5, "HD-1080p", "/media/tv"
)


def discovery(service):
    return {
        "profiles": [{"id": service.profile_id, "name": service.profile_name}],
        "rootFolders": [{"id": 1, "path": service.root_path}],
        "tags": [],
    }


def configured(service, identifier):
    value = {
        "id": identifier,
        "name": "Larenor " + service.service_id.title(),
        "hostname": service.hostname,
        "port": service.port,
        "apiKey": service.api_key,
        "useSsl": False,
        "baseUrl": "",
        "activeProfileId": service.profile_id,
        "activeProfileName": service.profile_name,
        "activeDirectory": service.root_path,
        "is4k": False,
        "isDefault": True,
        "externalUrl": "",
        "syncEnabled": True,
        "preventSearch": False,
    }
    if service.service_id == "radarr":
        value["minimumAvailability"] = "released"
    else:
        value["enableSeasonFolders"] = True
    return value


def test_wires_radarr_and_sonarr_with_verified_profile_and_root_folder():
    replies = []
    for identifier, service in enumerate((RADARR, SONARR), start=1):
        replies.extend(
            [
                response([]),
                response(discovery(service)),
                response(configured(service, identifier), status=201),
                response([configured(service, identifier)]),
            ]
        )
    connection = Connection(replies)
    result = SeerrArrWiring().configure(
        connection, seerr_api_key=API_KEY, services=(RADARR, SONARR)
    )

    assert result.state == "verified"
    assert result.service_ids == ("radarr", "sonarr")
    assert result.instance_ids == (1, 2)
    assert ARR_KEY not in repr(result)
    lines = [request(raw)[0][0] for raw in connection.requests]
    assert lines == [
        b"GET /api/v1/settings/radarr HTTP/1.1",
        b"POST /api/v1/settings/radarr/test HTTP/1.1",
        b"POST /api/v1/settings/radarr HTTP/1.1",
        b"GET /api/v1/settings/radarr HTTP/1.1",
        b"GET /api/v1/settings/sonarr HTTP/1.1",
        b"POST /api/v1/settings/sonarr/test HTTP/1.1",
        b"POST /api/v1/settings/sonarr HTTP/1.1",
        b"GET /api/v1/settings/sonarr HTTP/1.1",
    ]
    for raw in connection.requests:
        assert b"X-Api-Key: " + API_KEY.encode("ascii") in raw
    _, test_body = request(connection.requests[1])
    assert test_body == {
        "hostname": RADARR.hostname,
        "port": 7878,
        "apiKey": ARR_KEY,
        "useSsl": False,
        "baseUrl": "",
    }
    _, create_body = request(connection.requests[2])
    assert create_body == {key: value for key, value in configured(RADARR, 1).items() if key != "id"}


def test_exact_existing_instances_are_idempotent_without_mutation():
    connection = Connection(
        [response([configured(RADARR, 7)]), response([configured(SONARR, 9)])]
    )
    result = SeerrArrWiring().configure(
        connection, seerr_api_key=API_KEY, services=(RADARR, SONARR)
    )
    assert result.instance_ids == (7, 9)
    assert len(connection.requests) == 2
    assert all(request(raw)[0][0].startswith(b"GET ") for raw in connection.requests)


@pytest.mark.parametrize(
    "payload",
    [
        {"profiles": [], "rootFolders": [{"id": 1, "path": "/media/movies"}], "tags": []},
        {"profiles": [{"id": 4, "name": "HD-1080p"}], "rootFolders": [], "tags": []},
        {"profiles": [{"id": 4, "name": "HD-1080p", "secret": True}], "rootFolders": [], "tags": []},
        {"profiles": [{"id": True, "name": "HD-1080p"}], "rootFolders": [], "tags": []},
    ],
)
def test_discovery_schema_or_selection_drift_fails_before_create(payload):
    connection = Connection([response([]), response(payload, close=True)])
    with pytest.raises(SeerrArrWiringError, match="^seerr_arr_selection_changed$"):
        SeerrArrWiring().configure(
            connection, seerr_api_key=API_KEY, services=(RADARR, SONARR)
        )
    assert len(connection.requests) == 2


def test_foreign_existing_instance_fails_closed_without_overwrite():
    foreign = configured(RADARR, 3) | {"hostname": "foreign"}
    connection = Connection([response([foreign], close=True)])
    with pytest.raises(SeerrArrWiringError, match="^seerr_arr_conflict$") as raised:
        SeerrArrWiring().configure(
            connection, seerr_api_key=API_KEY, services=(RADARR, SONARR)
        )
    assert len(connection.requests) == 1
    assert ARR_KEY not in repr(raised.value)


def test_private_input_is_strict_and_secret_safe():
    assert ARR_KEY not in repr(RADARR)
    for args in (
        ("lidarr", RADARR.hostname, 7878, ARR_KEY, 4, "HD-1080p", "/media/movies"),
        ("radarr", "127.0.0.1", 7878, ARR_KEY, 4, "HD-1080p", "/media/movies"),
        ("radarr", RADARR.hostname, 8989, ARR_KEY, 4, "HD-1080p", "/media/movies"),
        ("radarr", RADARR.hostname, 7878, ARR_KEY, 4, "HD-1080p", "/data/movies"),
    ):
        with pytest.raises(SeerrArrWiringError, match="^invalid_seerr_arr_service$"):
            SeerrArrService(*args)

