from conftest import auth, ready

from larenor_server.camera_profiles import (
    CameraMode,
    CameraProfileAuthority,
    CameraProfileHttpGateway,
    CameraProfilePolicy,
    CameraProviderSupport,
    CameraReadback,
    CameraScope,
    PresenceSignal,
    WorkerReadback,
)
from larenor_server.camera_profiles.runtime import build_camera_profile_gateway


CAMERA_A = "6" * 32
CAMERA_B = "7" * 32
PROFILE = "5" * 32
AREA = "8" * 32
SOURCE = "9" * 32
SERVICE = "a" * 32
BINDING_A = "b" * 32
BINDING_B = "c" * 32
REQUEST = "d" * 32


def _scope(camera_id, binding_id):
    return CameraScope(
        schemaVersion=1,
        cameraId=camera_id,
        cameraRevision=2,
        areaId=AREA,
        areaRevision=3,
        serviceId=SERVICE,
        serviceRevision=4,
        bindingId=binding_id,
        bindingRevision=5,
    )


class Provider:
    def __init__(self, authority):
        self.current_authority = authority
        self.core_id = authority.coreId
        self.home_id = authority.homeId
        self.policy = CameraProfilePolicy(
            schemaVersion=1,
            coreId=authority.coreId,
            homeId=authority.homeId,
            profileId=PROFILE,
            profileRevision=7,
            presenceSourceId=SOURCE,
            presenceSourceRevision=8,
            cameras=[_scope(CAMERA_A, BINDING_A), _scope(CAMERA_B, BINDING_B)],
            enterDelayMs=0,
            exitDelayMs=0,
            hysteresisMs=0,
            presenceMaxAgeMs=60_000,
            atHomeMode=CameraMode(recording="paused", detection="disabled"),
            awayMode=CameraMode(recording="enabled", detection="enabled"),
            failSafeMode=CameraMode(recording="enabled", detection="enabled"),
            active=True,
        )
        self.signal = PresenceSignal(
            schemaVersion=1,
            coreId=authority.coreId,
            homeId=authority.homeId,
            sourceId=SOURCE,
            sourceRevision=8,
            signalRevision=9,
            observedAtMs=1_000_000,
            state="home",
        )
        self.readbacks = [
            CameraReadback(
                schemaVersion=1,
                coreId=authority.coreId,
                homeId=authority.homeId,
                camera=scope,
                stateRevision=10,
                mode=CameraMode(recording="enabled", detection="enabled"),
                observedAtMs=1_000_000,
            )
            for scope in self.policy.cameras
        ]
        self.support = [
            CameraProviderSupport(
                schemaVersion=1,
                camera=self.policy.cameras[0],
                displayName="Front door",
                providerRevision=11,
                recordingSupported=True,
                detectionSupported=True,
                verifiedAtMs=1_000_000,
            ),
            CameraProviderSupport(
                schemaVersion=1,
                camera=self.policy.cameras[1],
                displayName="Living room",
                providerRevision=12,
                recordingSupported=False,
                detectionSupported=False,
                verifiedAtMs=1_000_000,
            ),
        ]
        self.calls = []

    def authority(self, account_id):
        return self.current_authority if account_id == self.current_authority.accountId else None

    def policy_for(self, profile_id):
        return self.policy if profile_id == PROFILE else None

    def snapshot(self, actor):
        return self.current_authority, self.policy, self.signal, self.readbacks, self.support

    def apply(self, command):
        self.calls.append(command)
        return WorkerReadback(
            schemaVersion=1,
            commandId=command.commandId,
            camera=command.camera,
            stateRevision=command.expectedStateRevision + 1,
            mode=command.desiredMode,
            observedAtMs=1_000_001,
        )


def _configured(server):
    app, client, settings, _ = server
    pair = ready(server)
    principal = app.state.core.auth.authenticate(pair["accessToken"])
    context = app.state.core.context
    authority = CameraProfileAuthority(
        schemaVersion=1,
        coreId=context.coreId,
        homeId=context.homeId,
        homeRevision=1,
        accountId=pair["user"]["id"],
        accountRevision=1,
        sessionFamilyId=principal.family_id,
        role="admin",
        active=True,
        canManageCameraProfiles=True,
    )
    provider = Provider(authority)
    app.state.camera_profile_gateway = build_camera_profile_gateway(
        provider,
        master_key=b"k" * 32,
        clock=lambda: 1000.0,
    )
    root = f"/api/v1/admin/camera-profiles/{context.coreId}/{context.homeId}"
    return client, pair, root, provider


def test_authenticated_snapshot_exposes_support_and_never_claims_hardware_privacy(server):
    client, pair, root, _provider = _configured(server)
    assert client.get(root).status_code == 401
    response = client.get(root, headers=auth(pair))
    assert response.status_code == 200
    snapshot = response.json()["snapshot"]
    assert [item["recordingSupported"] for item in snapshot["support"]] == [True, False]
    assert snapshot["privacyBoundary"] == {
        "microphoneDisabled": False,
        "cameraHardwareDisabled": False,
        "otherRecordersDisabled": False,
    }
    assert snapshot["decision"]["reason"] == "presence_home"


def test_apply_returns_per_camera_partial_readback_and_never_replays_lost_ack(server):
    client, pair, root, provider = _configured(server)
    snapshot = client.get(root, headers=auth(pair)).json()["snapshot"]
    body = {
        "schemaVersion": 1,
        "requestId": REQUEST,
        "authority": snapshot["authority"],
        "policy": snapshot["policy"],
        "signal": snapshot["signal"],
        "decision": snapshot["decision"],
        "readbacks": snapshot["readbacks"],
        "support": snapshot["support"],
    }
    response = client.post(root + "/apply", headers=auth(pair), json=body)
    assert response.status_code == 200
    receipt = response.json()["receipt"]
    assert receipt["status"] == "partial"
    assert [(item["cameraId"], item["code"]) for item in receipt["results"]] == [
        (CAMERA_A, "applied"),
        (CAMERA_B, "provider_unsupported"),
    ]
    assert len(provider.calls) == 1
    replay = client.post(root + "/apply", headers=auth(pair), json=body)
    assert replay.json() == response.json()
    assert len(provider.calls) == 1


def test_provider_revision_or_session_drift_fails_closed_before_dispatch(server):
    client, pair, root, provider = _configured(server)
    snapshot = client.get(root, headers=auth(pair)).json()["snapshot"]
    provider.support[0] = provider.support[0].model_copy(update={"providerRevision": 99})
    body = {
        "schemaVersion": 1,
        "requestId": REQUEST,
        "authority": snapshot["authority"],
        "policy": snapshot["policy"],
        "signal": snapshot["signal"],
        "decision": snapshot["decision"],
        "readbacks": snapshot["readbacks"],
        "support": snapshot["support"],
    }
    response = client.post(root + "/apply", headers=auth(pair), json=body)
    assert response.status_code == 409
    assert response.json()["error"]["code"] == "revision_conflict"
    assert provider.calls == []
