import pytest
from fastapi.testclient import TestClient

from conftest import auth, ready
from larenor_server.app import create_app
from support.f41_frigate_fixture import provision
from support.f44_frigate_fixture import VisualFrigateFixture

RULE = '4' * 32


@pytest.fixture
def visual(server):
    upstream = VisualFrigateFixture()
    core = server[0].state.core
    pair = ready(server)
    _search, _setup, _source, cameras, _services = provision(server[1], core, pair, upstream)
    root = f'/api/v1/camera-visual-sensors/{core.context.coreId}/{core.context.homeId}'
    value = {'schemaVersion': 1, 'expectedRevision': 0, 'cameraId': cameras[0],
        'modelName': 'door', 'label': 'open', 'minimumConfidenceBps': 9000,
        'holdForMs': 1000, 'clearAfterMs': 1000, 'evidenceRetentionMs': 30000}
    yield upstream, pair, root, value
    upstream.close()
    assert upstream.errors == []


def bind(server, visual):
    _upstream, pair, root, value = visual
    response = server[1].put(root + '/sources/' + RULE, headers=auth(pair), json=value)
    assert response.status_code == 200, response.text
    assert response.json()['rule']['state'] == 'unknown'
    return response


def refresh(server, visual):
    return server[1].post(visual[2] + '/rules/' + RULE + '/refresh', headers=auth(visual[1]))


def test_normal_core_actual_classified_webp_hysteresis_restart_and_staleness(server, visual):
    upstream, pair, root, _value = visual
    bind(server, visual)
    server[3].now += 1
    upstream.attempt(server[3].now)
    first = refresh(server, visual)
    assert first.status_code == 200, first.text
    assert first.json()['rules'][0]['state'] == 'off'
    server[3].now += 2
    upstream.attempt(server[3].now)
    actual = refresh(server, visual)
    assert actual.status_code == 200, actual.text
    reading = actual.json()['rules'][0]
    assert reading['state'] == 'on' and reading['status'] == 'ready'
    assert reading['confidenceBps'] == 9600 and reading['count'] == 1
    assert reading['automationEligible'] is True and reading['accessControlEligible'] is False
    assert actual.json()['capability']['trainingSupported'] is False
    assert actual.json()['capability']['architecture'] == 'other'  # Remote host, not Core's CPU.
    with TestClient(create_app(server[2])) as restarted:
        current = restarted.get(root + '/summary', headers=auth(pair))
        assert current.status_code == 200, current.text
        assert current.json()['rules'][0] == reading
        server[3].now += 31
        stale = restarted.get(root + '/summary', headers=auth(pair))
        assert stale.status_code == 200, stale.text
        assert stale.json()['rules'][0]['state'] == 'unknown'
        assert stale.json()['rules'][0]['reason'] == 'stale_frame'
    assert not any(method == 'POST' for method, _path in upstream.calls)


def test_normal_provider_binds_observation_to_actual_home_registry_revision(
        server, visual, monkeypatch):
    upstream, _pair, _root, _value = visual
    bind(server, visual)
    core = server[0].state.core
    with core.db.connection() as connection:
        connection.execute('BEGIN')
        home_revision = core.home_resources._state(connection)['revision']
    assert home_revision > 1
    captured = {}
    original = core.camera_visual_sensors._engine.ingest

    def ingest(authority, rule, batch):
        captured.update(authority=authority, batch=batch)
        return original(authority, rule, batch)

    monkeypatch.setattr(core.camera_visual_sensors._engine, 'ingest', ingest)
    server[3].now += 2
    upstream.attempt(server[3].now)
    response = refresh(server, visual)
    assert response.status_code == 200, response.text
    assert captured['authority'].homeRevision == home_revision
    assert captured['batch'].homeRevision == home_revision


@pytest.mark.parametrize('change', ['untrained', 'multiple_cameras', 'bad_crop'])
def test_untrained_or_ambiguous_camera_model_cannot_bind(server, visual, change):
    upstream, pair, root, value = visual
    if change == 'untrained': upstream.has_trained = False
    elif change == 'multiple_cameras': upstream.model_cameras['back'] = {'crop': [0, 0, 1, 1]}
    else: upstream.model_cameras['front']['crop'] = [0, 0, 0, 0]
    response = server[1].put(root + '/sources/' + RULE, headers=auth(pair), json=value)
    assert response.status_code == 503, response.text
    assert server[1].get(root + '/summary', headers=auth(pair)).json()['rules'] == []


@pytest.mark.parametrize('change', ['corrupt_frame', 'permissions_during_frame', 'model_drift', 'bad_name', 'old_attempt'])
def test_bad_stale_or_changed_provider_never_yields_trusted_state(server, visual, change):
    upstream, pair, root, _value = visual
    if change == 'old_attempt': upstream.attempt(server[3].now - 1)
    bind(server, visual)
    server[3].now += 2
    if change != 'old_attempt': upstream.attempt(server[3].now)
    if change == 'corrupt_frame': upstream.frame = b'RIFF' + b'\0'*4 + b'WEBP' + b'bad!'
    elif change == 'permissions_during_frame': upstream.on_frame = lambda: upstream.allowed.clear()
    elif change == 'model_drift': upstream.training_date = '2026-09-05T12:00:01'
    elif change == 'bad_name': upstream.attempts = ['../../other.webp']
    response = refresh(server, visual)
    assert response.status_code == (200 if change == 'old_attempt' else 503 if change in {'corrupt_frame', 'bad_name'} else 409), response.text
    summary = server[0].state.core.camera_visual_sensors.summary(
        server[0].state.core.auth.authenticate(pair['accessToken']),
        server[0].state.core.context.coreId, server[0].state.core.context.homeId)
    assert summary['rules'][0].state == 'unknown'


def test_cancelled_refresh_does_not_store_and_http_metadata_cannot_claim_worker(server, visual):
    upstream, pair, root, _value = visual
    bind(server, visual)
    server[3].now += 2
    upstream.attempt(server[3].now)
    core = server[0].state.core
    actor = core.auth.authenticate(pair['accessToken'])
    from larenor_server.errors import ApiError
    with pytest.raises(ApiError, match='request_cancelled'):
        core.camera_visual_sensors.provider.refresh(actor, core.context.coreId, core.context.homeId,
            RULE, cancelled=lambda: True)
    assert not any(path.startswith('/clips/') for _, path in upstream.calls)
    assert core.camera_visual_sensors.summary(actor, core.context.coreId, core.context.homeId)['rules'][0].state == 'unknown'


def test_catalog_exposes_only_actual_trained_single_camera_models(server, visual):
    upstream, pair, root, value = visual
    response = server[1].get(root + '/sources/candidates/' + value['cameraId'], headers=auth(pair))
    assert response.status_code == 200, response.text
    model = response.json()['models'][0]
    assert model['name'] == 'door' and model['labels'] == ['closed', 'open']
    assert 1 <= model['revision'] <= 2**52
    upstream.has_trained = False
    response = server[1].get(root + '/sources/candidates/' + value['cameraId'], headers=auth(pair))
    assert response.status_code == 200 and response.json()['models'] == []
    assert server[1].get(root + '/sources/candidates/' + '0'*32, headers=auth(pair)).status_code == 403


def test_encrypted_source_and_rule_reset_commit_atomically(server, visual, monkeypatch):
    from larenor_server.errors import ApiError
    core = server[0].state.core
    def failed(*_args, **_kwargs):
        raise ApiError('visual_sensor_storage_unavailable', 503)
    monkeypatch.setattr(core.camera_visual_sensors.provider.store, 'put', failed)
    response = server[1].put(visual[2] + '/sources/' + RULE, headers=auth(visual[1]), json=visual[3])
    assert response.status_code == 503
    with core.db.connection() as connection:
        assert connection.execute('SELECT COUNT(*) FROM camera_visual_sensor_rules').fetchone()[0] == 0
    assert core.camera_visual_sensors._rules == {}


def test_normal_core_public_metadata_ingress_cannot_mint_classified_evidence(server, visual):
    from test_f44_camera_visual_sensors import batch
    bind(server, visual)
    core = server[0].state.core
    value = batch('9'*32, int(server[3].now*1000)).model_dump(mode='json')
    rule = core.camera_visual_sensors._rules[RULE]
    value.update(coreId=core.context.coreId, homeId=core.context.homeId, homeRevision=1,
                 cameraId=rule.cameraId, pipelineId=rule.pipelineId, pipelineRevision=rule.pipelineRevision,
                 modelId=rule.modelId, modelRevision=rule.modelRevision)
    response = server[1].post(visual[2] + '/rules/' + RULE + '/observations', headers=auth(visual[1]), json={
        'schemaVersion': 1, 'expectedRuleRevision': rule.ruleRevision, 'batch': value,
        'capability': {'schemaVersion': 1, 'architecture': 'other', 'avx': 'unknown', 'avx2': 'unknown',
            'arm64': False, 'detectorState': 'ready', 'trainingSupported': False, 'inferenceSupported': True, 'reason': 'ready'}})
    assert response.status_code == 503, response.text
    assert response.json()['error']['code'] == 'server_unavailable'  # Private failure reason is redacted.
    assert core.camera_visual_sensors.summary(core.auth.authenticate(visual[1]['accessToken']),
        core.context.coreId, core.context.homeId)['rules'][0].state == 'unknown'
