import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/media/playback_quality/data/core_playback_quality_api.dart';
import 'package:larenor/features/media/playback_quality/domain/core_playback_quality_advice.dart';
import 'package:larenor/features/server/data/larenor_server_api.dart';
import 'package:larenor/features/server/domain/server_models.dart';

const _token = 'synthetic_quality_access_token_1234567890';
const _requestId = 'abcdefabcdefabcdefabcdefabcdefab';
const _coreId = '11111111111111111111111111111111';
const _homeId = '22222222222222222222222222222222';
const _accountId = '33333333333333333333333333333333';
const _familyId = '44444444444444444444444444444444';

final class _QualityCore {
  _QualityCore._(this.server, {this.wrongFamily = false}) {
    unawaited(_serve());
  }

  final HttpServer server;
  final bool wrongFamily;
  String? path;
  String? authorization;
  Map<String, dynamic>? body;

  static Future<_QualityCore> start({bool wrongFamily = false}) async =>
      _QualityCore._(
        await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
        wrongFamily: wrongFamily,
      );

  String get baseUrl => 'http://127.0.0.1:${server.port}';

  Future<void> _serve() async {
    await for (final request in server) {
      path = request.uri.path;
      authorization = request.headers.value(HttpHeaders.authorizationHeader);
      body = Map<String, dynamic>.from(
        jsonDecode(await utf8.decoder.bind(request).join()) as Map,
      );
      final response = {
        'schemaVersion': 1,
        'authority': {
          'schemaVersion': 1,
          'coreId': _coreId,
          'homeId': _homeId,
          'accountId': _accountId,
          'accountRevision': 6,
          'sessionFamilyId': wrongFamily ? '9' * 32 : _familyId,
        },
        'requestId': _requestId,
        'advisoryOnly': true,
        'physicalAcceptance': 'manual',
        'method': 'transcode',
        'confidence': 'reported',
        'evidence': {
          'schemaVersion': 1,
          'codec': 'reported',
          'bitrate': 'reported',
          'network': 'reported',
          'receiver': 'reported',
          'hdr': 'reported',
        },
        'gaps': <String>[],
        'reasons': [
          'server_transcode',
          'bitrate_limit',
          'audio_codec_mismatch',
        ],
        'recommendations': [
          {
            'schemaVersion': 1,
            'code': 'lower_bitrate',
            'maxBitrateBps': 14000000,
            'processingLoad': 'high',
          },
          {
            'schemaVersion': 1,
            'code': 'prefer_compatible_audio',
            'maxBitrateBps': null,
            'processingLoad': 'medium',
          },
        ],
      };
      request.response
        ..headers.contentType = ContentType.json
        ..write(jsonEncode(response));
      await request.response.close();
    }
  }
}

ServerSession _session(_QualityCore core) => ServerSession(
  endpoint: ServerEndpoint(core.baseUrl),
  accessToken: _token,
  refreshToken: 'synthetic_quality_refresh_token_123456789',
  expiresAt: DateTime.utc(2027),
  user: const ServerUser(
    id: _accountId,
    username: 'viewer',
    role: ServerRole.member,
    mustChangePassword: false,
  ),
  sessionFamilyId: _familyId,
  context: ServerContext.fromJson(const {
    'schemaVersion': 1,
    'coreId': _coreId,
    'homeId': _homeId,
  }),
);

const _qualityRequest = CorePlaybackQualityRequest(
  media: CorePlaybackMediaEvidence(
    state: CorePlaybackEvidenceState.reported,
    sourceId: 'main-source',
    container: 'mkv',
    videoCodec: 'hevc',
    audioCodec: 'eac3',
    subtitleCodec: 'srt',
    bitrateBps: 25000000,
    width: 3840,
    height: 2160,
    hdr: CorePlaybackHdr.hdr10,
    serverDecision: CorePlaybackMethod.transcode,
    transcodeReasons: [
      CorePlaybackTranscodeReason.bitrate,
      CorePlaybackTranscodeReason.audioCodec,
    ],
  ),
  receiver: CorePlaybackReceiverEvidence(
    state: CorePlaybackEvidenceState.reported,
    videoCodecs: ['hevc'],
    audioCodecs: ['aac'],
    subtitleFormats: [],
    maxWidth: 3840,
    maxHeight: 2160,
    hdrTypes: [CorePlaybackHdr.hdr10],
  ),
  network: CorePlaybackNetworkEvidence(
    state: CorePlaybackEvidenceState.reported,
    transport: CorePlaybackTransport.wifi,
    downstreamKbps: 20000,
    metered: false,
  ),
);

void main() {
  setUpAll(() => HttpOverrides.global = null);
  tearDownAll(() => HttpOverrides.global = null);

  test(
    'production quality client crosses loopback Core with bounded evidence',
    () async {
      final core = await _QualityCore.start();
      addTearDown(() => core.server.close(force: true));
      final session = _session(core);
      final api = LarenorServerApi(endpoint: session.endpoint);
      addTearDown(api.close);

      final advice = await CorePlaybackQualityApi(
        api,
        session,
        requestId: () => _requestId,
      ).advise(_qualityRequest);

      expect(
        core.path,
        '/api/v1/media/playback-quality/$_coreId/$_homeId/advice',
      );
      expect(core.authorization, 'Bearer $_token');
      expect(core.body, _qualityRequest.toJson(_requestId));
      expect(advice.method, CorePlaybackMethod.transcode);
      expect(advice.confidence, CorePlaybackEvidenceState.reported);
      expect(advice.gaps, isEmpty);
      expect(advice.recommendations.map((value) => value.code), [
        CorePlaybackRecommendationCode.lowerBitrate,
        CorePlaybackRecommendationCode.preferCompatibleAudio,
      ]);
      expect(advice.recommendations.first.maxBitrateBps, 14000000);
    },
  );

  test('production quality client rejects another session family', () async {
    final core = await _QualityCore.start(wrongFamily: true);
    addTearDown(() => core.server.close(force: true));
    final session = _session(core);
    final api = LarenorServerApi(endpoint: session.endpoint);
    addTearDown(api.close);

    await expectLater(
      CorePlaybackQualityApi(
        api,
        session,
        requestId: () => _requestId,
      ).advise(_qualityRequest),
      throwsA(
        isA<LarenorServerException>().having(
          (error) => error.code,
          'code',
          'invalid_response',
        ),
      ),
    );
  });
}
