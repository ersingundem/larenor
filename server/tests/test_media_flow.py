import json
import os
from pathlib import Path
import tempfile
import time

from conftest import auth, ready
from fastapi.testclient import TestClient
import pytest
from larenor_server.app import create_app
from larenor_server.config import Settings
from larenor_server.plugins.installation_ipc import (
    InstallationIPCError,
    InstallationWorkerClient,
    InstallationWorkerServer,
)
from larenor_server.plugins.media_archive_health_models import (
    ArrArchiveSnapshot,
    JellyfinArchiveSnapshot,
    QbittorrentArchiveSnapshot,
)
from larenor_server.plugins.media_flow_models import (
    MediaFlowPathEvidence,
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


def delivery_evidence(*, series=False, attempt=1, effect_state="verified"):
    media_key = "series:tvdb:101" if series else "movie:tmdb:603"
    item_keys = (
        ["episode:tvdb:101:1:1"] if series else [media_key]
    )
    return {
        "mediaKey": media_key,
        "operationId": "2" * 32,
        "requestReceiptId": "3" * 32,
        "retryAttempt": attempt,
        "effectState": effect_state,
        "files": [
            {
                "mediaKey": item_key,
                "torrentId": "a" * 40,
                "importReceiptId": "4" * 32,
                "playbackItemId": "c" * 32,
                "paths": [
                    {
                        "provider": "qbittorrent",
                        "containerRoot": "/data/downloads",
                        "containerPath": "/data/downloads/movies/The.Matrix.mkv",
                        "hostRoot": "/srv/larenor/media/downloads",
                        "device": 41,
                        "inode": 9001,
                    },
                    {
                        "provider": "sonarr" if series else "radarr",
                        "containerRoot": "/media",
                        "containerPath": "/media/movies/The.Matrix.mkv",
                        "hostRoot": "/srv/larenor/media/library",
                        "device": 41,
                        "inode": 9001,
                    },
                    {
                        "provider": "jellyfin",
                        "containerRoot": "/media",
                        "containerPath": "/media/movies/The.Matrix.mkv",
                        "hostRoot": "/srv/larenor/media/library",
                        "device": 41,
                        "inode": 9001,
                    },
                ],
            }
            for item_key in item_keys
        ],
    }


def observation(*, revision=4, observed=NOW - 10, series=False,
                delivery=True, attempt=1, effect_state="verified"):
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
        delivery=(delivery_evidence(
            series=series, attempt=attempt, effect_state=effect_state,
        ) if delivery else None),
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


def test_hardlink_inode_and_canonical_mapping_prove_one_secret_free_file_chain(
        server):
    pair = ready(server)
    current = authority(
        server, pair, "movie:tmdb:603", Provider([observation()]))
    response = read(server, pair, current)
    assert response.status_code == 200, response.text
    delivery = response.json()["flow"]["delivery"]
    assert delivery == {
        "state": "hardlink_verified",
        "retryAttempt": 1,
        "fileCount": 1,
    }
    assert all(private not in response.text for private in (
        "/data/downloads", "/srv/larenor", "9001", "The.Matrix.mkv",
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    ))

    server[0].state.core.media_flow.provider = Provider([
        observation(revision=5, delivery=False)])
    unproved = server[1].post(
        BASE + "/authority",
        headers=auth(pair),
        json={"requestId": "e" * 32, "mediaKey": "movie:tmdb:603"},
    )
    assert unproved.status_code == 409
    assert unproved.json()["error"]["code"] == "media_flow_effect_uncertain"


@pytest.mark.parametrize("field,value", [
    ("containerPath", "/data/downloads/../private/movie.mkv"),
    ("containerPath", "/data/downloads//movies/movie.mkv"),
    ("containerPath", "data/downloads/movies/movie.mkv"),
    ("containerPath", "/data/downloads-other/movie.mkv"),
    ("hostRoot", "/srv/larenor/media/../private"),
])
def test_container_host_mapping_rejects_noncanonical_or_escaping_paths(
        field, value):
    raw = delivery_evidence()["files"][0]["paths"][0]
    with pytest.raises(ValueError):
        MediaFlowPathEvidence.model_validate({**raw, field: value})


def test_container_host_mapping_resolves_only_the_relative_canonical_suffix():
    raw = delivery_evidence()["files"][0]["paths"][0]
    evidence = MediaFlowPathEvidence.model_validate(raw)
    assert evidence.resolved_host_path() == (
        "/srv/larenor/media/downloads/movies/The.Matrix.mkv")

    same_target = delivery_evidence()["files"][0]
    same_target["paths"][0] = {
        **same_target["paths"][1],
        "provider": "qbittorrent",
    }
    with pytest.raises(ValueError):
        MediaFlowObservation.model_validate({
            **observation().model_dump(mode="python"),
            "delivery": {
                **delivery_evidence(),
                "files": [same_target],
            },
        })


def test_interrupted_retry_is_idempotent_and_uncertain_effect_fails_closed(
        server):
    pair = ready(server)
    first_provider = Provider([observation()])
    first = authority(server, pair, "movie:tmdb:603", first_provider)
    first_read = read(server, pair, first)
    assert first_read.status_code == 200, first_read.text

    retry_provider = Provider([observation(revision=5, attempt=2)])
    retry = authority(server, pair, "movie:tmdb:603", retry_provider)
    retried = read(server, pair, retry)
    assert retried.status_code == 200, retried.text
    flow = retried.json()["flow"]
    assert flow["delivery"] == {
        "state": "hardlink_verified",
        "retryAttempt": 2,
        "fileCount": 1,
    }
    assert len(flow["seasons"]) == 0
    assert [stage["name"] for stage in flow["stages"]] == [
        "request", "download", "import", "playable",
    ]

    uncertain_provider = Provider([
        observation(revision=6, attempt=3, effect_state="uncertain")])
    server[0].state.core.media_flow.provider = uncertain_provider
    uncertain = server[1].post(
        BASE + "/authority",
        headers=auth(pair),
        json={"requestId": "e" * 32, "mediaKey": "movie:tmdb:603"},
    )
    assert uncertain.status_code == 409
    assert uncertain.json()["error"]["code"] == "media_flow_effect_uncertain"
    assert "path" not in uncertain.text.lower()

    verified_provider = Provider([observation(revision=6, attempt=3)])
    accepted = authority(server, pair, "movie:tmdb:603", verified_provider)
    assert accepted["flowRevision"] == 6


@pytest.mark.parametrize("rebound", [
    "request", "torrent", "import", "playback", "inode",
])
def test_retry_rejects_rebound_request_import_playback_or_file_identity(
        server, rebound):
    pair = ready(server)
    first = authority(
        server, pair, "movie:tmdb:603", Provider([observation()]))
    assert read(server, pair, first).status_code == 200

    changed = observation(revision=5, attempt=2).model_dump(mode="python")
    if rebound == "request":
        changed["delivery"]["requestReceiptId"] = "5" * 32
    elif rebound == "torrent":
        changed["delivery"]["files"][0]["torrentId"] = "b" * 40
        changed["qbittorrent"]["items"][0]["torrentId"] = "b" * 40
    elif rebound == "import":
        changed["delivery"]["files"][0]["importReceiptId"] = "5" * 32
    elif rebound == "playback":
        changed["delivery"]["files"][0]["playbackItemId"] = "5" * 32
        changed["jellyfin"]["items"][0]["itemId"] = "5" * 32
    else:
        for path in changed["delivery"]["files"][0]["paths"]:
            path["inode"] = 9002
    changed_provider = Provider([MediaFlowObservation.model_validate(changed)])
    server[0].state.core.media_flow.provider = changed_provider
    response = server[1].post(
        BASE + "/authority",
        headers=auth(pair),
        json={"requestId": "e" * 32, "mediaKey": "movie:tmdb:603"},
    )
    assert response.status_code == 409
    assert response.json()["error"]["code"] == "media_flow_authority_changed"


def test_retry_rejects_duplicate_season_request_import_and_playback():

    duplicate = observation(revision=5, attempt=2).model_dump(mode="python")
    duplicate["delivery"]["files"].append(
        duplicate["delivery"]["files"][0])
    with pytest.raises(ValueError):
        MediaFlowObservation.model_validate(duplicate)

    duplicate_season = observation(series=True).model_dump(mode="python")
    duplicate_season["seerr"]["requests"][0]["requestedSeasons"] = [1, 1]
    with pytest.raises(ValueError):
        MediaFlowObservation.model_validate(duplicate_season)


@pytest.mark.parametrize("tamper", [
    "UPDATE media_flow_delivery_journal SET integrity_tag=zeroblob(32)",
    "UPDATE media_flow_file_journal SET integrity_tag=zeroblob(32)",
])
def test_retry_journal_tamper_fails_closed_without_private_evidence(
        server, tamper):
    pair = ready(server)
    current = authority(
        server, pair, "movie:tmdb:603", Provider([observation()]))
    assert read(server, pair, current).status_code == 200
    with server[0].state.core.db.transaction() as connection:
        connection.execute(tamper)
    server[0].state.core.media_flow.provider = Provider([
        observation(revision=5, attempt=2)])
    response = server[1].post(
        BASE + "/authority",
        headers=auth(pair),
        json={"requestId": "e" * 32, "mediaKey": "movie:tmdb:603"},
    )
    assert response.status_code == 503
    assert response.json()["error"]["code"] == (
        "media_flow_storage_unavailable")
    assert "/srv/larenor" not in response.text


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


class WorkerFlowBackend:
    def __init__(self, values):
        self.values = list(values)
        self.calls = []

    def read_media_flow(self, media_key, *, deadline, gate):
        assert gate() is True
        self.calls.append(media_key)
        return self.values.pop(0) if len(self.values) > 1 else self.values[0]


def test_worker_flow_contract_rejects_cancelled_or_secret_bearing_results():
    base = "/private/tmp" if Path("/private/tmp").is_dir() else "/tmp"
    secret = "private-worker-token"
    backend = WorkerFlowBackend([
        {**observation().model_dump(mode="json"), "token": secret}
    ])
    with tempfile.TemporaryDirectory(prefix="mfw-", dir=base) as root:
        worker_path = Path(root) / "installation.sock"
        worker = InstallationWorkerServer(
            worker_path,
            backend,
            allowed_uid=os.getuid(),
            peer_uid=lambda _connection: os.getuid(),
            timeout=1,
        )
        worker.start()
        try:
            client = InstallationWorkerClient(
                worker_path,
                owner_uid=os.getuid(),
                peer_uid=lambda _connection: os.getuid(),
                timeout=1,
            )
            with pytest.raises(InstallationIPCError) as cancelled:
                client.read_media_flow(
                    "movie:tmdb:603",
                    deadline=time.monotonic() + 1,
                    gate=lambda: False,
                )
            assert backend.calls == []
            with pytest.raises(InstallationIPCError) as invalid:
                client.read_media_flow(
                    "movie:tmdb:603",
                    deadline=time.monotonic() + 1,
                    gate=lambda: True,
                )
            assert backend.calls == ["movie:tmdb:603"]
            assert secret not in repr(cancelled.value)
            assert secret not in repr(invalid.value)
        finally:
            worker.close()


def test_configured_core_worker_is_the_default_media_flow_provider(
        tmp_path, monkeypatch):
    base = "/private/tmp" if Path("/private/tmp").is_dir() else "/tmp"
    with tempfile.TemporaryDirectory(prefix="mfw-", dir=base) as root:
        worker_path = Path(root) / "installation.sock"
        backend = WorkerFlowBackend([observation()])
        worker = InstallationWorkerServer(
            worker_path,
            backend,
            allowed_uid=os.getuid(),
            peer_uid=lambda _connection: os.getuid(),
            timeout=1,
        )
        worker.start()
        try:
            monkeypatch.setattr(
                "larenor_server.core.InstallationWorkerClient",
                lambda path, *, owner_uid: InstallationWorkerClient(
                    path,
                    owner_uid=owner_uid,
                    peer_uid=lambda _connection: os.getuid(),
                    timeout=1,
                ),
            )
            settings = Settings(
                tmp_path / "data",
                tmp_path / "secrets/vault.key",
                clock=lambda: NOW,
                login_ip_limit=100,
                login_account_limit=100,
                login_global_limit=100,
                installation_worker_socket=worker_path,
                installation_worker_uid=os.getuid(),
            )
            app = create_app(settings)
            with TestClient(app) as client:
                pair = ready((app, client, settings, None))
                first = client.post(
                    BASE + "/authority",
                    headers=auth(pair),
                    json={"requestId": "e" * 32,
                          "mediaKey": "movie:tmdb:603"},
                )
                assert first.status_code == 200, first.text
                projected = client.post(
                    BASE + "/read",
                    headers=auth(pair),
                    json={
                        "requestId": "f" * 32,
                        "mediaKey": first.json()["mediaKey"],
                        "expectedFlowRevision": first.json()["flowRevision"],
                        "expectedSources": first.json()["sources"],
                    },
                )
                assert projected.status_code == 200, projected.text
                assert projected.json()["flow"]["state"] == "playable"
                assert app.state.core.media_flow.provider.backend is \
                    app.state.core.media_installations.backend
                assert backend.calls == ["movie:tmdb:603"] * 4
                assert "token" not in projected.text.lower()
        finally:
            worker.close()
