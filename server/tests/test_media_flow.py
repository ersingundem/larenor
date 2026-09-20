import json

from conftest import auth, ready
from larenor_server.plugins.media_archive_health_models import (
    ArrArchiveSnapshot,
    JellyfinArchiveSnapshot,
    QbittorrentArchiveSnapshot,
)
from larenor_server.plugins.media_flow_models import (
    MediaFlowObservation,
    SeerrFlowSnapshot,
)


NOW = 1_788_609_600
BASE = "/api/v1/admin/media/flows"


class Provider:
    def __init__(self, values):
        self.values = list(values)
        self.calls = []

    def current(self, media_key):
        self.calls.append(media_key)
        return self.values.pop(0) if len(self.values) > 1 else self.values[0]


def source(service, *, revision=4, observed=NOW - 10):
    return {
        "serviceRecordId": {
            "seerr": "5",
            "jellyfin": "6",
            "sonarr": "7",
            "radarr": "8",
            "qbittorrent": "9",
        }[service] * 32,
        "serviceRevision": {
            "seerr": 7,
            "jellyfin": 8,
            "sonarr": 9,
            "radarr": 10,
            "qbittorrent": 11,
        }[service],
        "snapshotRevision": revision,
        "installationId": "1" * 32,
        "installationRevision": 12,
        "state": "verified",
        "observedAt": observed,
    }


def observation(*, revision=4, observed=NOW - 10, series=False):
    target = "series:tvdb:101" if series else "movie:tmdb:603"
    requests = [{
        "mediaKey": target,
        "state": "approved",
        "requestedSeasons": [1, 2] if series else [],
    }]
    sonarr = []
    radarr = []
    torrents = []
    jellyfin = []
    if series:
        sonarr = [
            {
                "mediaKey": "episode:tvdb:101:1:1",
                "title": "S01E01",
                "mediaKind": "episode",
                "monitored": True,
                "state": "available",
            },
            {
                "mediaKey": "episode:tvdb:101:1:2",
                "title": "S01E02",
                "mediaKind": "episode",
                "monitored": True,
                "state": "missing",
            },
            {
                "mediaKey": "episode:tvdb:101:3:1",
                "title": "S03E01",
                "mediaKind": "episode",
                "monitored": True,
                "state": "available",
            },
            {
                "mediaKey": "episode:tvdb:101:4:1",
                "title": "S04E01",
                "mediaKind": "episode",
                "monitored": True,
                "state": "missing",
            },
        ]
        torrents = [
            {
                "torrentId": "a" * 40,
                "mediaKey": "episode:tvdb:101:1:1",
                "title": "S01E01 download",
                "contentBytes": 100,
                "state": "complete",
                "importedConfirmed": True,
                "retentionPolicySatisfied": False,
            },
            {
                "torrentId": "b" * 40,
                "mediaKey": "episode:tvdb:101:1:2",
                "title": "S01E02 download",
                "contentBytes": 100,
                "state": "complete",
                "importedConfirmed": False,
                "retentionPolicySatisfied": False,
            },
            {
                "torrentId": "e" * 40,
                "mediaKey": None,
                "title": "Unmatched download",
                "contentBytes": 100,
                "state": "downloading",
                "importedConfirmed": False,
                "retentionPolicySatisfied": False,
            },
        ]
        jellyfin = [
            {
                "itemId": "c" * 32,
                "mediaKey": "episode:tvdb:101:1:1",
                "title": "S01E01",
                "mediaKind": "episode",
                "sizeBytes": 100,
                "integrity": "playable",
            },
            {
                "itemId": "d" * 32,
                "mediaKey": "episode:tvdb:101:3:1",
                "title": "S03E01",
                "mediaKind": "episode",
                "sizeBytes": 100,
                "integrity": "playable",
            },
        ]
    else:
        radarr = [{
            "mediaKey": target,
            "title": "The Matrix",
            "mediaKind": "movie",
            "monitored": True,
            "state": "available",
        }]
        torrents = [{
            "torrentId": "a" * 40,
            "mediaKey": target,
            "title": "The Matrix download",
            "contentBytes": 100,
            "state": "complete",
            "importedConfirmed": True,
            "retentionPolicySatisfied": False,
        }]
        jellyfin = [{
            "itemId": "c" * 32,
            "mediaKey": target,
            "title": "The Matrix",
            "mediaKind": "movie",
            "sizeBytes": 100,
            "integrity": "playable",
        }]
    return MediaFlowObservation(
        flowRevision=revision,
        seerr=SeerrFlowSnapshot(
            **source("seerr", revision=revision, observed=observed),
            requests=requests,
        ),
        qbittorrent=QbittorrentArchiveSnapshot(
            serviceId="qbittorrent",
            **source("qbittorrent", revision=revision, observed=observed),
            items=torrents,
        ),
        sonarr=ArrArchiveSnapshot(
            serviceId="sonarr",
            **source("sonarr", revision=revision, observed=observed),
            items=sonarr,
        ),
        radarr=ArrArchiveSnapshot(
            serviceId="radarr",
            **source("radarr", revision=revision, observed=observed),
            items=radarr,
        ),
        jellyfin=JellyfinArchiveSnapshot(
            serviceId="jellyfin",
            **source("jellyfin", revision=revision, observed=observed),
            items=jellyfin,
        ),
    )


def authority(server, pair, media_key, provider):
    server[0].state.core.media_flow.provider = provider
    response = server[1].post(
        BASE + "/authority",
        headers=auth(pair),
        json={"requestId": "e" * 32, "mediaKey": media_key},
    )
    assert response.status_code == 200, response.text
    return response.json()


def read(server, pair, current):
    return server[1].post(
        BASE + "/read",
        headers=auth(pair),
        json={
            "requestId": "f" * 32,
            "mediaKey": current["mediaKey"],
            "expectedFlowRevision": current["flowRevision"],
            "expectedSources": current["sources"],
        },
    )


def test_core_combines_request_download_import_and_playable_revisions(server):
    pair = ready(server)
    provider = Provider([observation()])
    current = authority(server, pair, "movie:tmdb:603", provider)
    response = read(server, pair, current)
    assert response.status_code == 200, response.text
    flow = response.json()["flow"]
    assert flow["state"] == "playable"
    assert [(stage["name"], stage["state"], stage["provider"])
            for stage in flow["stages"]] == [
        ("request", "complete", "seerr"),
        ("download", "complete", "qbittorrent"),
        ("import", "complete", "radarr"),
        ("playable", "complete", "jellyfin"),
    ]
    assert [item["provider"] for item in flow["sources"]] == [
        "seerr", "qbittorrent", "sonarr", "radarr", "jellyfin",
    ]
    assert [item["serviceRevision"] for item in flow["sources"]] == [
        7, 11, 9, 10, 8,
    ]
    assert provider.calls == ["movie:tmdb:603"] * 4
    assert "token" not in json.dumps(flow).lower()


def test_series_exposes_missing_partial_and_existing_seasons_without_rerequest(server):
    pair = ready(server)
    provider = Provider([observation(series=True)])
    current = authority(server, pair, "series:tvdb:101", provider)
    response = read(server, pair, current)
    assert response.status_code == 200, response.text
    flow = response.json()["flow"]
    assert flow["state"] == "partial"
    seasons = {item["seasonNumber"]: item for item in flow["seasons"]}
    assert seasons[1] == {
        "seasonNumber": 1,
        "knownEpisodes": [1, 2],
        "downloadedEpisodes": [1, 2],
        "importedEpisodes": [1],
        "playableEpisodes": [1],
        "missingEpisodes": [2],
        "requested": True,
        "requestable": False,
        "incomplete": True,
        "missingSeason": False,
        "partialImport": True,
    }
    assert seasons[2]["missingSeason"] is True
    assert seasons[2]["incomplete"] is True
    assert seasons[2]["requestable"] is False
    assert seasons[3]["playableEpisodes"] == [1]
    assert seasons[3]["requested"] is False
    assert seasons[3]["requestable"] is False
    assert seasons[3]["incomplete"] is False
    assert seasons[4]["missingSeason"] is True
    assert seasons[4]["requestable"] is True


def test_stale_replayed_changed_and_unknown_provider_results_fail_closed(server):
    pair = ready(server)
    stale_provider = Provider([observation(observed=NOW - 301)])
    server[0].state.core.media_flow.provider = stale_provider
    stale = server[1].post(
        BASE + "/authority",
        headers=auth(pair),
        json={"requestId": "e" * 32, "mediaKey": "movie:tmdb:603"},
    )
    assert stale.status_code == 409
    assert stale.json()["error"]["code"] == "media_flow_snapshot_stale"

    provider = Provider([observation()])
    current = authority(server, pair, "movie:tmdb:603", provider)
    provider.values = [observation(revision=5)]
    replay = read(server, pair, current)
    assert replay.status_code == 409
    assert replay.json()["error"]["code"] == "media_flow_authority_changed"

    provider.values = [observation()]
    rolled_back = server[1].post(
        BASE + "/authority",
        headers=auth(pair),
        json={"requestId": "e" * 32, "mediaKey": "movie:tmdb:603"},
    )
    assert rolled_back.status_code == 409
    assert rolled_back.json()["error"]["code"] == "media_flow_snapshot_replayed"

    invalid = observation()
    object.__setattr__(invalid.seerr, "serviceId", "unknown")
    server[0].state.core.media_flow.provider = Provider([invalid])
    unknown = server[1].post(
        BASE + "/authority",
        headers=auth(pair),
        json={"requestId": "e" * 32, "mediaKey": "movie:tmdb:603"},
    )
    assert unknown.status_code == 503
    assert unknown.json()["error"]["code"] == "media_flow_provider_unavailable"
    assert "unknown" not in unknown.text

    server[0].state.core.media_flow.provider = Provider([
        observation(), observation(revision=5),
    ])
    changed = server[1].post(
        BASE + "/authority",
        headers=auth(pair),
        json={"requestId": "e" * 32, "mediaKey": "movie:tmdb:603"},
    )
    assert changed.status_code == 409
    assert changed.json()["error"]["code"] == "media_flow_authority_changed"

    with server[0].state.core.db.transaction() as connection:
        connection.execute(
            "UPDATE media_flow_high_water SET integrity_tag=zeroblob(32) "
            "WHERE media_key=?",
            ("movie:tmdb:603",),
        )
    tampered = server[1].post(
        BASE + "/authority",
        headers=auth(pair),
        json={"requestId": "e" * 32, "mediaKey": "movie:tmdb:603"},
    )
    assert tampered.status_code == 503
    assert tampered.json()["error"]["code"] == "media_flow_storage_unavailable"


def test_default_provider_and_untrusted_request_fields_never_claim_a_flow(server):
    pair = ready(server)
    unavailable = server[1].post(
        BASE + "/authority",
        headers=auth(pair),
        json={"requestId": "e" * 32, "mediaKey": "movie:tmdb:603"},
    )
    assert unavailable.status_code == 503
    assert unavailable.json()["error"]["code"] == "media_flow_provider_unavailable"

    server[0].state.core.media_flow.provider = Provider([observation()])
    invalid = server[1].post(
        BASE + "/authority",
        headers=auth(pair),
        json={
            "requestId": "e" * 32,
            "mediaKey": "movie:tmdb:603",
            "provider": "unknown",
            "token": "private-value",
        },
    )
    assert invalid.status_code == 400
    assert "private-value" not in invalid.text
    assert server[0].state.core.media_flow.provider.calls == []
