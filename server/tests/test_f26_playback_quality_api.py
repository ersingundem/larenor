from conftest import auth, ready
from larenor_server.plugins.media_playback_models import (
    PlaybackInfoReadback,
    PrivateMediaPlaybackAuthority,
    local_playback_profile_digest,
)
from test_media_archive_core_read import configured


def scope(server, pair):
    context = server[1].get('/api/v1/context', headers=auth(pair)).json()
    return (
        f"/api/v1/media/playback-quality/{context['coreId']}/"
        f"{context['homeId']}/advice"
    )


def observe_scope(server, pair):
    context = server[1].get('/api/v1/context', headers=auth(pair)).json()
    return (
        f"/api/v1/media/playback-quality/{context['coreId']}/"
        f"{context['homeId']}/observe-item"
    )


def observation_request():
    return {
        'schemaVersion': 1,
        'requestId': 'd' * 32,
        'installationId': 'e' * 32,
        'expectedInstallationRevision': 4,
        'expectedSnapshotRevision': 8,
        'expectedJellyfinServiceRevision': 6,
        'itemId': 'f' * 32,
        'mediaKey': 'movie:tmdb:603',
        'localProfile': {
            'schemaVersion': 1,
            'evidence': 'client_reported',
            'profileId': '9' * 32,
            'profileRevision': 1,
            'displayRevision': 2,
            'decoderRevision': 3,
            'networkRevision': 4,
            'policyRevision': 5,
            'containers': ['mkv', 'mp4'],
            'videoCodecs': ['h264', 'hevc'],
            'audioCodecs': ['aac', 'eac3'],
            'subtitleFormats': ['srt'],
            'maxWidth': 3840,
            'maxHeight': 2160,
            'maxStreamingBitrateBps': 40_000_000,
        },
    }


class PlaybackInfoProvider:
    def __init__(self, revision):
        self.revision = revision
        self.calls = []

    def playback_info(self, actor, body):
        self.calls.append((actor, body))
        return (
            self.revision,
            PrivateMediaPlaybackAuthority(
                installationId=body.installationId,
                installationRevision=body.expectedInstallationRevision,
                snapshotRevision=body.expectedSnapshotRevision,
                jellyfinServiceRevision=(
                    body.expectedJellyfinServiceRevision),
                itemId=body.itemId,
                mediaKey=body.mediaKey,
            ),
            PlaybackInfoReadback(
                itemId=body.itemId,
                profileDigest=local_playback_profile_digest(body.profile),
                assurance=(
                    'provider_observed_for_client_reported_profile'),
                originalByteOutcome='direct_play_supported',
                playMethod='direct_play',
                source={
                    'container': 'mkv', 'bitrate': 25_000_000,
                    'videoCodecs': ['hevc'],
                    'audioCodecs': ['eac3'],
                    'videoRanges': ['HDR10'],
                },
                transcoding=None,
                reason='available',
            ),
        )

    def record_playback_info_observation(
            self, actor, revision, private, profile, readback):
        assert actor == self.calls[-1][0]
        assert revision == self.revision
        assert private.itemId == readback.itemId
        assert readback.profileDigest == local_playback_profile_digest(profile)
        return '8' * 32, 1788609600, 1788609630


class CorePlaybackInfoWorker:
    def __init__(self, change=None, profile_digest=None):
        self.calls = []
        self.change = change
        self.profile_digest = profile_digest

    def read_playback_info(
            self, authority, *, request_id, profile,
            expected_content_length, deadline, gate):
        assert deadline > 0 and gate() is True
        self.calls.append((
            authority, request_id, profile, expected_content_length))
        if self.change is not None:
            self.change()
        return PlaybackInfoReadback(
            itemId=authority.itemId,
            profileDigest=(self.profile_digest
                           or local_playback_profile_digest(profile)),
            assurance='provider_observed_for_client_reported_profile',
            originalByteOutcome='direct_play_supported',
            playMethod='direct_play',
            source={
                'container': 'mkv', 'bitrate': 25_000_000,
                'videoCodecs': ['hevc'], 'audioCodecs': ['eac3'],
                'videoRanges': ['HDR10'],
            },
            transcoding=None, reason='available')


def complete_request():
    return {
        'schemaVersion': 1,
        'requestId': 'a' * 32,
        'media': {
            'state': 'verified',
            'sourceId': 'main-source',
            'container': 'mkv',
            'videoCodec': 'hevc',
            'audioCodec': 'eac3',
            'subtitleCodec': 'srt',
            'bitrateBps': 25_000_000,
            'width': 3840,
            'height': 2160,
            'hdr': 'hdr10',
            'serverDecision': 'direct_play',
            'transcodeReasons': [],
        },
        'receiver': {
            'state': 'verified',
            'videoCodecs': ['hevc'],
            'audioCodecs': ['eac3'],
            'subtitleFormats': ['srt'],
            'maxWidth': 3840,
            'maxHeight': 2160,
            'hdrTypes': ['hdr10'],
        },
        'network': {
            'state': 'reported',
            'transport': 'ethernet',
            'downstreamKbps': 100_000,
            'metered': False,
        },
    }


def unknown_request():
    return {
        'schemaVersion': 1,
        'requestId': 'b' * 32,
        'media': {
            'state': 'unknown',
            'sourceId': 'unknown-source',
            'container': None,
            'videoCodec': None,
            'audioCodec': None,
            'subtitleCodec': None,
            'bitrateBps': None,
            'width': None,
            'height': None,
            'hdr': None,
            'serverDecision': 'unknown',
            'transcodeReasons': [],
        },
        'receiver': {
            'state': 'unknown',
            'videoCodecs': [],
            'audioCodecs': [],
            'subtitleFormats': [],
            'maxWidth': None,
            'maxHeight': None,
            'hdrTypes': [],
        },
        'network': {
            'state': 'unknown',
            'transport': None,
            'downstreamKbps': None,
            'metered': None,
        },
    }


def test_http_core_explains_direct_play_from_bounded_evidence(server):
    pair = ready(server)
    response = server[1].post(
        scope(server, pair), headers=auth(pair), json=complete_request())

    assert response.status_code == 200, response.text
    value = response.json()
    assert value['requestId'] == 'a' * 32
    assert value['advisoryOnly'] is True
    assert value['physicalAcceptance'] == 'manual'
    assert value['method'] == 'direct_play'
    assert value['confidence'] == 'reported'
    assert value['evidence'] == {
        'schemaVersion': 1,
        'codec': 'verified',
        'bitrate': 'verified',
        'network': 'reported',
        'receiver': 'verified',
        'hdr': 'verified',
    }
    assert value['gaps'] == []
    assert value['reasons'] == ['server_direct_play']
    assert value['recommendations'] == [{
        'schemaVersion': 1,
        'code': 'keep_original',
        'maxBitrateBps': None,
        'processingLoad': 'low',
    }]
    assert value['authority']['accountId'] == pair['user']['id']
    assert value['authority']['sessionFamilyId'] == pair['sessionFamilyId']


def test_missing_telemetry_is_explicit_and_never_claims_quality(server):
    pair = ready(server)
    response = server[1].post(
        scope(server, pair), headers=auth(pair), json=unknown_request())

    assert response.status_code == 200, response.text
    value = response.json()
    assert value['method'] == 'unknown'
    assert value['confidence'] == 'unknown'
    assert value['gaps'] == [
        'source_telemetry_missing',
        'codec_telemetry_missing',
        'bitrate_telemetry_missing',
        'network_telemetry_missing',
        'receiver_telemetry_missing',
        'hdr_telemetry_missing',
    ]
    assert [item['code'] for item in value['recommendations']] == [
        'inspect_receiver', 'measure_network', 'verify_hdr_on_device']


def test_scope_auth_and_bounded_contract_fail_closed(server):
    pair = ready(server)
    path = scope(server, pair)
    assert server[1].post(path, json=complete_request()).status_code == 401

    context = server[1].get('/api/v1/context', headers=auth(pair)).json()
    wrong_scope = (
        f"/api/v1/media/playback-quality/{'f' * 32}/"
        f"{context['homeId']}/advice"
    )
    missing = server[1].post(
        wrong_scope, headers=auth(pair), json=complete_request())
    assert missing.status_code == 404
    assert missing.json()['error']['code'] == 'not_found'

    invalid = complete_request()
    invalid['receiver']['videoCodecs'] = ['hevc'] * 33
    bounded = server[1].post(path, headers=auth(pair), json=invalid)
    assert bounded.status_code == 400
    assert bounded.json()['error']['code'] == 'invalid_request'


def test_transcode_bitrate_advice_uses_conservative_reported_limits(server):
    pair = ready(server)
    body = complete_request()
    body['requestId'] = 'c' * 32
    body['media']['state'] = 'reported'
    body['media']['serverDecision'] = 'transcode'
    body['media']['transcodeReasons'] = ['bitrate', 'network', 'audio_codec']
    body['network']['downstreamKbps'] = 20_000

    response = server[1].post(
        scope(server, pair), headers=auth(pair), json=body)

    assert response.status_code == 200, response.text
    value = response.json()
    assert value['method'] == 'transcode'
    assert value['physicalAcceptance'] == 'manual'
    assert value['reasons'] == [
        'server_transcode', 'bitrate_limit', 'network_limit',
        'audio_codec_mismatch',
    ]
    assert value['recommendations'][0] == {
        'schemaVersion': 1,
        'code': 'lower_bitrate',
        'maxBitrateBps': 14_000_000,
        'processingLoad': 'high',
    }
    assert value['recommendations'][1]['code'] == 'prefer_compatible_audio'


def test_core_observes_provider_playback_info_without_exposing_private_ids(
        server):
    pair = ready(server)
    app, client, _settings, clock = server
    with app.state.core.db.connection() as connection:
        revision = connection.execute(
            'SELECT revision FROM users WHERE id=?',
            (pair['user']['id'],)).fetchone()['revision']
    provider = PlaybackInfoProvider(revision)
    app.state.core.playback_quality.media_playback = lambda: provider

    response = client.post(
        observe_scope(server, pair), headers=auth(pair),
        json=observation_request())

    assert response.status_code == 200, response.text
    value = response.json()
    assert value['requestId'] == 'd' * 32
    assert value['observationId'] == '8' * 32
    assert value['authority'] == {
        'schemaVersion': 1,
        'coreId': value['authority']['coreId'],
        'homeId': value['authority']['homeId'],
        'accountId': pair['user']['id'],
        'accountRevision': revision,
        'sessionFamilyId': pair['sessionFamilyId'],
        'installationId': 'e' * 32,
        'installationRevision': 4,
        'snapshotRevision': 8,
        'jellyfinServiceRevision': 6,
        'itemId': 'f' * 32,
        'mediaKey': 'movie:tmdb:603',
        'profileId': '9' * 32,
        'profileRevision': 1,
        'displayRevision': 2,
        'decoderRevision': 3,
        'networkRevision': 4,
        'policyRevision': 5,
        'profileDigest': local_playback_profile_digest(
            provider.calls[0][1].profile),
    }
    assert value['observation'] == {
        'schemaVersion': 1,
        'assurance': 'provider_observed_for_client_reported_profile',
        'originalByteOutcome': 'direct_play_supported',
        'playMethod': 'direct_play',
        'source': {
            'container': 'mkv', 'bitrateBps': 25_000_000,
            'videoCodecs': ['hevc'], 'audioCodecs': ['eac3'],
            'videoRanges': ['HDR10'],
        },
        'transcoding': None,
        'reason': 'available',
        'advisoryOnly': True,
        'physicalAcceptance': 'manual',
        'observedAt': int(clock.now),
        'expiresAt': int(clock.now) + 30,
    }
    assert len(provider.calls) == 1
    assert provider.calls[0][1].profile.evidence == 'client_reported'
    assert all(value not in response.text for value in (
        'private-media-source', 'PlaySessionId', 'MediaSourceId',
        'apiKey', 'http://', 'https://'))


def test_playback_info_profile_is_canonical_and_never_accepts_unsorted_facts(
        server):
    pair = ready(server)
    body = observation_request()
    body['localProfile']['containers'] = ['mp4', 'mkv']

    response = server[1].post(
        observe_scope(server, pair), headers=auth(pair), json=body)

    assert response.status_code == 400
    assert response.json()['error']['code'] == 'invalid_request'


def test_normal_core_binds_archive_item_and_profile_to_one_worker_read(server):
    app, client, _settings, _clock = server
    pair, installation, current, _reader, _archive, _body = configured(server)
    jellyfin = next(
        value for value in current.sources if value.serviceId == 'jellyfin')
    body = observation_request() | {
        'installationId': installation['id'],
        'expectedInstallationRevision': installation['revision'],
        'expectedSnapshotRevision': current.snapshotRevision,
        'expectedJellyfinServiceRevision': jellyfin.serviceRevision,
        'itemId': 'b' * 32,
    }
    worker = CorePlaybackInfoWorker()
    app.state.core.media_playback.backend = worker

    response = client.post(
        observe_scope(server, pair), headers=auth(pair), json=body)

    assert response.status_code == 200, response.text
    assert len(response.json()['observationId']) == 32
    assert response.json()['authority']['installationId'] == installation['id']
    assert response.json()['authority']['profileDigest'] == (
        local_playback_profile_digest(worker.calls[0][2]))
    assert response.json()['observation']['originalByteOutcome'] == (
        'direct_play_supported')
    assert len(worker.calls) == 1
    authority, request_id, profile, content_length = worker.calls[0]
    assert request_id == 'd' * 32
    assert profile.evidence == 'client_reported'
    assert content_length > 0
    assert authority.itemId == 'b' * 32


def test_normal_core_post_read_authority_drift_returns_no_observation(server):
    app, client, _settings, _clock = server
    pair, installation, current, _reader, _archive, _body = configured(server)
    jellyfin = next(
        value for value in current.sources if value.serviceId == 'jellyfin')
    body = observation_request() | {
        'installationId': installation['id'],
        'expectedInstallationRevision': installation['revision'],
        'expectedSnapshotRevision': current.snapshotRevision,
        'expectedJellyfinServiceRevision': jellyfin.serviceRevision,
        'itemId': 'b' * 32,
    }

    def drift():
        with app.state.core.db.transaction() as connection:
            connection.execute(
                'UPDATE users SET revision=revision+1 WHERE id=?',
                (pair['user']['id'],))

    worker = CorePlaybackInfoWorker(change=drift)
    app.state.core.media_playback.backend = worker

    response = client.post(
        observe_scope(server, pair), headers=auth(pair), json=body)

    assert response.status_code == 409
    assert response.json()['error']['code'] == (
        'media_playback_authority_changed')
    assert len(worker.calls) == 1
    assert 'observation' not in response.text


def test_normal_core_rejects_worker_profile_digest_substitution(server):
    app, client, _settings, _clock = server
    pair, installation, current, _reader, _archive, _body = configured(server)
    jellyfin = next(
        value for value in current.sources if value.serviceId == 'jellyfin')
    body = observation_request() | {
        'installationId': installation['id'],
        'expectedInstallationRevision': installation['revision'],
        'expectedSnapshotRevision': current.snapshotRevision,
        'expectedJellyfinServiceRevision': jellyfin.serviceRevision,
        'itemId': 'b' * 32,
    }
    worker = CorePlaybackInfoWorker(profile_digest='0' * 64)
    app.state.core.media_playback.backend = worker

    response = client.post(
        observe_scope(server, pair), headers=auth(pair), json=body)

    assert response.status_code == 503
    assert 'observation' not in response.text
    assert len(worker.calls) == 1
