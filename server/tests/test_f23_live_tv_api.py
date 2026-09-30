from fastapi.testclient import TestClient

from conftest import auth, ready
from larenor_server.app import create_app
from larenor_server.live_tv.runtime import (
    LiveTvProviderCapability,
    LiveTvRecordingReadback,
    LiveTvRecordingReceipt,
)


PROVIDER_REVISION = 7
SOURCE_REQUEST = "1" * 32
FIRST_PROGRAMME = "2" * 32
CONFLICT_PROGRAMME = "3" * 32
QUOTA_PROGRAMME = "4" * 32
SCHEDULE_REQUEST = "5" * 32
CONFLICT_REQUEST = "6" * 32
QUOTA_REQUEST = "7" * 32
RESTART_REQUEST = "8" * 32
INTERRUPT_REQUEST = "9" * 32
SECOND_INTERRUPT_REQUEST = "a" * 32
CANCEL_REQUEST = "b" * 32


class AuthorizedLiveTvFixture:
    def __init__(self, clock):
        self.clock = clock
        self.commands = []
        self.readbacks = {}
        self.provider_ids = {}

    def capability(self):
        return LiveTvProviderCapability(
            provider_id="synthetic-tuner",
            provider_kind="tuner",
            provider_revision=PROVIDER_REVISION,
            parallel_tuners=1,
            quota_bytes=1_073_741_824,
        )

    def apply(self, command):
        self.commands.append(command)
        provider_id = self.provider_ids.setdefault(
            command.recording_id, f"capture-{command.recording_id}"
        )
        previous = self.readbacks.get(provider_id)
        revision = 1 if previous is None else previous.readback_revision + 1
        state = {
            "schedule": "recording",
            "restart": "recording",
            "cancel": "cancelled",
        }[command.action]
        readback = LiveTvRecordingReadback(
            provider_recording_id=provider_id,
            provider_revision=PROVIDER_REVISION,
            readback_revision=revision,
            state=state,
            bytes_written=0 if previous is None else previous.bytes_written,
            observed_at=int(self.clock.now),
        )
        self.readbacks[provider_id] = readback
        return LiveTvRecordingReceipt(
            request_id=command.request_id,
            action=command.action,
            recording_id=command.recording_id,
            provider_recording_id=provider_id,
            provider_revision=PROVIDER_REVISION,
            readback=readback,
        )

    def readback(self, provider_recording_id):
        return self.readbacks[provider_recording_id]

    def interrupted(self, recording_id, *, revision, bytes_written):
        provider_id = self.provider_ids[recording_id]
        self.readbacks[provider_id] = LiveTvRecordingReadback(
            provider_recording_id=provider_id,
            provider_revision=PROVIDER_REVISION,
            readback_revision=revision,
            state="interrupted",
            bytes_written=bytes_written,
            observed_at=int(self.clock.now),
        )


def _programme(identity, channel, title, starts_at, ends_at):
    return {
        "schemaVersion": 1,
        "programmeId": identity,
        "channelId": channel,
        "channelName": title + " channel",
        "title": title,
        "startsAt": starts_at,
        "endsAt": ends_at,
    }


def _bind(app, fixture):
    app.state.core.live_tv.provider = fixture
    app.state.core.live_tv.recorder = fixture


def test_authorized_provider_schedule_receipt_conflict_quota_restart_partial_and_cancel(
    server,
):
    app, client, settings, clock = server
    pair = ready(server)
    fixture = AuthorizedLiveTvFixture(clock)
    _bind(app, fixture)
    root = "/api/v1/media/live-tv"
    now = int(clock.now)
    programmes = [
        _programme(FIRST_PROGRAMME, "c" * 32, "News", now - 60, now + 540),
        _programme(
            CONFLICT_PROGRAMME,
            "d" * 32,
            "Sports",
            now + 60,
            now + 300,
        ),
        _programme(
            QUOTA_PROGRAMME,
            "e" * 32,
            "Documentary",
            now + 540,
            now + 1140,
        ),
    ]
    configured = client.put(
        root + "/source",
        headers=auth(pair),
        json={
            "schemaVersion": 1,
            "requestId": SOURCE_REQUEST,
            "expectedRevision": 0,
            "providerId": "synthetic-tuner",
            "providerKind": "tuner",
            "providerRevision": PROVIDER_REVISION,
            "timeZone": "Europe/Istanbul",
            "parallelTuners": 1,
            "quotaBytes": 1_073_741_824,
            "capturedAt": now,
            "programmes": programmes,
        },
    )
    assert configured.status_code == 200, configured.text
    source_revision = configured.json()["snapshot"]["authority"]["sourceRevision"]

    schedule_body = {
        "schemaVersion": 1,
        "requestId": SCHEDULE_REQUEST,
        "expectedSourceRevision": source_revision,
        "expectedProviderRevision": PROVIDER_REVISION,
        "programmeId": FIRST_PROGRAMME,
    }
    scheduled = client.post(root + "/recordings", headers=auth(pair), json=schedule_body)
    replay = client.post(root + "/recordings", headers=auth(pair), json=schedule_body)
    assert scheduled.status_code == 201 and replay.status_code == 201
    recording = scheduled.json()["recording"]
    assert replay.json()["recording"] == recording
    assert [command.action for command in fixture.commands] == ["schedule"]

    with TestClient(create_app(settings)) as restarted:
        _bind(restarted.app, fixture)
        snapshot = restarted.get(root, headers=auth(pair))
        assert snapshot.status_code == 200, snapshot.text
        assert snapshot.json()["snapshot"]["recordings"][0] == recording

        conflict = restarted.post(
            root + "/recordings",
            headers=auth(pair),
            json={**schedule_body, "requestId": CONFLICT_REQUEST,
                  "programmeId": CONFLICT_PROGRAMME},
        )
        assert conflict.status_code == 409
        assert conflict.json()["error"]["code"] == "live_tv_recording_conflict"

        quota = restarted.post(
            root + "/recordings",
            headers=auth(pair),
            json={**schedule_body, "requestId": QUOTA_REQUEST,
                  "programmeId": QUOTA_PROGRAMME},
        )
        assert quota.status_code == 409
        assert quota.json()["error"]["code"] == "live_tv_quota_exceeded"

        interrupted = restarted.post(
            f"{root}/recordings/{recording['recordingId']}/interrupt",
            headers=auth(pair),
            json={
                "schemaVersion": 1,
                "requestId": INTERRUPT_REQUEST,
                "expectedRevision": recording["revision"],
                "bytesWritten": 100,
                "providerRevision": PROVIDER_REVISION,
                "readbackRevision": 2,
            },
        )
        assert interrupted.status_code == 200, interrupted.text
        interrupted_recording = interrupted.json()["recording"]
        assert interrupted_recording["state"] == "interrupted"
        fixture.interrupted(
            recording["recordingId"], revision=2, bytes_written=100
        )

        resumed = restarted.post(
            f"{root}/recordings/{recording['recordingId']}/restart",
            headers=auth(pair),
            json={
                "schemaVersion": 1,
                "requestId": RESTART_REQUEST,
                "expectedRevision": interrupted_recording["revision"],
            },
        )
        assert resumed.status_code == 200, resumed.text
        resumed_recording = resumed.json()["recording"]
        assert resumed_recording["state"] == "recording"
        assert resumed_recording["restartCount"] == 1

        interrupted_again = restarted.post(
            f"{root}/recordings/{recording['recordingId']}/interrupt",
            headers=auth(pair),
            json={
                "schemaVersion": 1,
                "requestId": SECOND_INTERRUPT_REQUEST,
                "expectedRevision": resumed_recording["revision"],
                "bytesWritten": 200,
                "providerRevision": PROVIDER_REVISION,
                "readbackRevision": 4,
            },
        )
        assert interrupted_again.status_code == 200, interrupted_again.text
        fixture.interrupted(
            recording["recordingId"], revision=4, bytes_written=200
        )
        clock.now = now + 541
        partial_snapshot = restarted.get(root, headers=auth(pair))
        assert partial_snapshot.status_code == 200, partial_snapshot.text
        partial = partial_snapshot.json()["snapshot"]["recordings"][0]
        assert partial["state"] == "partial"

        cancelled = restarted.post(
            f"{root}/recordings/{recording['recordingId']}/cancel",
            headers=auth(pair),
            json={
                "schemaVersion": 1,
                "requestId": CANCEL_REQUEST,
                "expectedRevision": partial["revision"],
            },
        )
        assert cancelled.status_code == 200, cancelled.text
        assert cancelled.json()["recording"]["state"] == "cancelled"
        assert [command.action for command in fixture.commands] == [
            "schedule",
            "restart",
            "cancel",
        ]
