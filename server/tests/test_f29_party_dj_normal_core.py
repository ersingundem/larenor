import http.client
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import socket
import threading

from fastapi.testclient import TestClient

from conftest import auth
from larenor_server.app import create_app
from larenor_server.plugins.music_playback_runtime import MusicPlaybackRuntime
from test_admin import activate, create
from test_music_assistant_core_wiring import TOKEN
from test_music_manager_api import ready_manager
from test_music_playback_runtime import raw_player, raw_queue


BASE = "/api/v1/media/party-dj/rooms"


class _QuietServer(ThreadingHTTPServer):
    def handle_error(self, _request, _client_address):
        pass


class MusicAssistantFixture:
    def __init__(self):
        self.calls = []
        self.queue_count = 1
        self.lose_next_effect_ack = False

        owner = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *_args):
                pass

            def do_POST(self):
                if (self.path != "/api"
                        or self.headers.get("Authorization")
                        != "Bearer " + TOKEN):
                    self.send_error(403)
                    return
                try:
                    length = int(self.headers.get("Content-Length", "0"))
                except ValueError:
                    self.send_error(400)
                    return
                if not 1 <= length <= 32 * 1024:
                    self.send_error(400)
                    return
                try:
                    body = json.loads(self.rfile.read(length))
                    if (type(body) is not dict
                            or set(body) != {"message_id", "command", "args"}
                            or type(body["message_id"]) is not str
                            or type(body["command"]) is not str
                            or type(body["args"]) is not dict):
                        raise ValueError()
                except (UnicodeError, ValueError, TypeError):
                    self.send_error(400)
                    return
                command, args = body["command"], body["args"]
                owner.calls.append((command, args))
                if command == "player_queues/all":
                    value = [raw_queue(count=owner.queue_count)]
                elif command == "players/all":
                    value = [raw_player()]
                elif command == "players/get":
                    value = raw_player()
                elif command == "music/search":
                    value = {"tracks": [{
                        "uri": "spotify://track/party-fixture",
                        "name": "Party fixture",
                        "provider": "spotify--fixture",
                        "artists": [{"name": "Fixture artist"}],
                    }]}
                elif command == "player_queues/play_media":
                    if args != {
                            "queue_id": "homepod-living",
                            "media": ["spotify://track/party-fixture"],
                            "option": "add", "radio_mode": False}:
                        self.send_error(400)
                        return
                    owner.queue_count += 1
                    value = None
                    if owner.lose_next_effect_ack:
                        owner.lose_next_effect_ack = False
                        self.close_connection = True
                        try:
                            self.connection.shutdown(socket.SHUT_RDWR)
                        except OSError:
                            pass
                        self.connection.close()
                        return
                elif command == "players/cmd/next":
                    value = None
                else:
                    self.send_error(400)
                    return
                payload = json.dumps(value, separators=(",", ":")).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)

        self.server = _QuietServer(("127.0.0.1", 0), Handler)
        self.thread = threading.Thread(
            target=self.server.serve_forever, daemon=True,
        )

    def __enter__(self):
        self.thread.start()
        return self

    def __exit__(self, *_args):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=5)

    def backend(self):
        runtime = MusicPlaybackRuntime(
            lambda timeout: http.client.HTTPConnection(
                "127.0.0.1", self.server.server_port, timeout=timeout,
            )
        )

        class Backend:
            @staticmethod
            def _run(callback, value, *, deadline, gate):
                if gate() is not True:
                    raise RuntimeError("authority_changed")
                result = callback(value, deadline=deadline)
                if gate() is not True:
                    raise RuntimeError("authority_changed")
                return result

            def read_music_players(self, value, *, deadline, gate):
                return self._run(runtime.read, value, deadline=deadline, gate=gate)

            def search_music_catalog(self, value, *, deadline, gate):
                return self._run(runtime.search, value, deadline=deadline, gate=gate)

            def execute_music_playback(self, value, *, deadline, gate):
                return self._run(runtime.execute, value, deadline=deadline, gate=gate)

        return Backend()


def _party(server, upstream):
    app, client, _settings, clock = server
    admin, setup, readiness, _worker, manager = ready_manager(server)
    app.state.core.music_playback.backend = upstream.backend()
    create(client, admin, "party-member")
    member = activate(client, "party-member")
    receiver = manager["receivers"][0]
    created = client.post(BASE, headers=auth(admin), json={
        "schemaVersion": 1,
        "requestId": "3" * 32,
        "installationId": setup["installationId"],
        "expectedInstallationRevision": setup["installationRevision"],
        "expectedCoreRevision": readiness["revision"],
        "expectedManagerRevision": manager["revision"],
        "expectedPlayerRevision": manager["revision"],
        "targetId": receiver["playerId"],
        "expectedProvider": receiver["provider"],
        "expectedTargetKind": receiver["targetKind"],
        "expectedQueueId": receiver["queueId"],
        "expectedGroupMembers": receiver["groupMembers"],
        "expiresAt": int(clock()) + 3600,
        "proposalLimitPerUser": 3,
        "skipQuorumPercent": 60,
    })
    assert created.status_code == 201, created.text
    room, invite = created.json()["room"], created.json()["inviteCode"]
    joined = client.post(
        f"{BASE}/{room['authority']['roomId']}/join",
        headers=auth(member), json={
            "schemaVersion": 1, "requestId": "4" * 32,
            "inviteCode": invite, "expectedRoomRevision": room["revision"],
        },
    )
    assert joined.status_code == 200, joined.text
    room = joined.json()["room"]
    provider = manager["providers"][0]
    proposed = client.post(
        f"{BASE}/{room['authority']['roomId']}/proposals",
        headers=auth(member), json={
            "schemaVersion": 1, "requestId": "5" * 32,
            "catalogRequestId": "6" * 32,
            "expectedRoomRevision": room["revision"],
            "catalogQuery": "Party fixture",
            "mediaUri": "spotify://track/party-fixture",
            "name": "Party fixture",
            "providerSetupId": provider["setupId"],
            "expectedProviderRevision": provider["revision"],
            "providerDomain": provider["providerDomain"],
            "providerInstanceId": provider["providerInstanceId"],
        },
    )
    assert proposed.status_code == 201, proposed.text
    return admin, member, proposed.json()["room"]


def _vote(client, admin, room, request_id="7" * 32):
    proposal = room["proposals"][0]
    body = {
        "schemaVersion": 1, "requestId": request_id,
        "expectedRoomRevision": room["revision"],
        "expectedProposalRevision": proposal["revision"],
        "vote": "up",
    }
    response = client.post(
        f"{BASE}/{room['authority']['roomId']}/proposals/"
        f"{proposal['proposalId']}/votes",
        headers=auth(admin), json=body,
    )
    assert response.status_code == 200, response.text
    return body, response.json()["room"]


def _approve(client, admin, room, request_id="8" * 32):
    proposal = room["proposals"][0]
    body = {
        "schemaVersion": 1, "requestId": request_id,
        "expectedRoomRevision": room["revision"],
        "expectedProposalRevision": proposal["revision"],
        "decision": "approve",
        "expectedPlayerRevision": room["authority"]["playerRevision"],
    }
    response = client.post(
        f"{BASE}/{room['authority']['roomId']}/proposals/"
        f"{proposal['proposalId']}/decision",
        headers=auth(admin), json=body,
    )
    assert response.status_code == 200, response.text
    return body, response.json()["room"]


def _skip(client, pair, room, request_id):
    body = {
        "schemaVersion": 1, "requestId": request_id,
        "expectedRoomRevision": room["revision"],
        "expectedParticipantRevision": room["currentParticipantRevision"],
        "expectedPlayerRevision": room["authority"]["playerRevision"],
    }
    response = client.post(
        f"{BASE}/{room['authority']['roomId']}/skip-votes",
        headers=auth(pair), json=body,
    )
    assert response.status_code == 200, response.text
    return response.json()["room"]


def test_normal_core_party_queue_survives_restart_and_duplicate_vote(server):
    app, client, settings, _clock = server
    with MusicAssistantFixture() as upstream:
        admin, member, room = _party(server, upstream)
        vote_body, room = _vote(client, admin, room)
        assert room["proposals"][0]["upVotes"] == 2

        replay = client.post(
            f"{BASE}/{room['authority']['roomId']}/proposals/"
            f"{room['proposals'][0]['proposalId']}/votes",
            headers=auth(admin), json=vote_body,
        )
        assert replay.status_code == 200
        assert replay.json()["room"] == room
        assert room["proposals"][0]["upVotes"] == 2

        with TestClient(create_app(settings)) as restarted:
            restarted.app.state.core.music_playback.backend = upstream.backend()
            snapshot = restarted.get(
                f"{BASE}/{room['authority']['roomId']}", headers=auth(admin),
            )
            assert snapshot.status_code == 200, snapshot.text
            assert snapshot.json()["room"]["proposals"][0]["upVotes"] == 2
            _body, approved = _approve(
                restarted, admin, snapshot.json()["room"],
            )
            assert approved["proposals"][0]["status"] == "approved"
            first_skip = _skip(restarted, admin, approved, "9" * 32)
            assert first_skip["skipVotes"] == 1
            member_snapshot = restarted.get(
                f"{BASE}/{room['authority']['roomId']}", headers=auth(member),
            )
            assert member_snapshot.status_code == 200, member_snapshot.text
            skipped = _skip(
                restarted, member, member_snapshot.json()["room"], "a" * 32,
            )
            assert skipped["skipVotes"] == 0
            assert skipped["skipNeedsAttention"] is False

        assert [item[0] for item in upstream.calls].count(
            "player_queues/play_media"
        ) == 1
        assert [item[0] for item in upstream.calls].count(
            "players/cmd/next"
        ) == 1
        assert upstream.queue_count == 2
        assert TOKEN not in json.dumps(upstream.calls)
        app.state.core.party_dj.validate_storage()


def test_lost_queue_ack_is_never_resent_and_becomes_attention_after_restart(
        server):
    _app, client, settings, clock = server
    with MusicAssistantFixture() as upstream:
        admin, _member, room = _party(server, upstream)
        upstream.lose_next_effect_ack = True
        body, claimed = _approve(client, admin, room)
        assert claimed["proposals"][0]["status"] == "approving"
        effect_count = [item[0] for item in upstream.calls].count(
            "player_queues/play_media"
        )
        assert effect_count == 1 and upstream.queue_count == 2

        retry = client.post(
            f"{BASE}/{room['authority']['roomId']}/proposals/"
            f"{room['proposals'][0]['proposalId']}/decision",
            headers=auth(admin), json=body,
        )
        assert retry.status_code == 200, retry.text
        assert retry.json()["room"]["proposals"][0]["status"] == "approving"

        with TestClient(create_app(settings)) as restarted:
            restarted.app.state.core.music_playback.backend = upstream.backend()
            repeated = restarted.post(
                f"{BASE}/{room['authority']['roomId']}/proposals/"
                f"{room['proposals'][0]['proposalId']}/decision",
                headers=auth(admin), json=body,
            )
            assert repeated.status_code == 200, repeated.text
            assert repeated.json()["room"]["proposals"][0]["status"] == "approving"
            clock.now += 11
            settled = restarted.get(
                f"{BASE}/{room['authority']['roomId']}", headers=auth(admin),
            )
            assert settled.status_code == 200, settled.text
            assert settled.json()["room"]["proposals"][0]["status"] == "needs_attention"

        assert [item[0] for item in upstream.calls].count(
            "player_queues/play_media"
        ) == effect_count
