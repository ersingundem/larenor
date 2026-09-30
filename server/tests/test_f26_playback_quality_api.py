from conftest import auth, ready


def scope(server, pair):
    context = server[1].get('/api/v1/context', headers=auth(pair)).json()
    return (
        f"/api/v1/media/playback-quality/{context['coreId']}/"
        f"{context['homeId']}/advice"
    )


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
