import 'dart:math';

import '../../../server/data/larenor_server_api.dart';
import '../../../server/domain/server_models.dart';
import '../domain/core_playback_quality_advice.dart';

/// One-shot advisory call. It never retries because a timed-out POST has an
/// uncertain result, even though the operation is read-only from the user's
/// perspective.
final class CorePlaybackQualityApi {
  CorePlaybackQualityApi(
    this._api,
    this._session, {
    String Function()? requestId,
  }) : _requestId = requestId ?? _randomId;

  final LarenorServerApi _api;
  final ServerSession _session;
  final String Function() _requestId;

  Future<CorePlaybackQualityAdvice> advise(
    CorePlaybackQualityRequest request,
  ) async {
    final context = _session.context;
    if (context == null || _session.sessionFamilyId == null) {
      throw const LarenorServerException('invalid_session');
    }
    final requestId = _requestId();
    if (!RegExp(r'^[0-9a-f]{32}$').hasMatch(requestId) ||
        !_validRequest(request)) {
      throw const LarenorServerException('invalid_request');
    }
    final response = await _api.request(
      'POST',
      '/media/playback-quality/${context.coreId}/${context.homeId}/advice',
      token: _session.accessToken,
      body: request.toJson(requestId),
    );
    return CorePlaybackQualityAdvice.fromJson(
      response,
      session: _session,
      requestId: requestId,
    );
  }

  static String _randomId() {
    final random = Random.secure();
    return List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }
}

bool _validRequest(CorePlaybackQualityRequest request) {
  final media = request.media;
  final receiver = request.receiver;
  final network = request.network;
  bool token(String value, {int maximum = 64}) =>
      value.isNotEmpty &&
      value.length <= maximum &&
      RegExp(r'^[A-Za-z0-9_.:+-]+$').hasMatch(value);
  bool optionalToken(String? value) => value == null || token(value);
  bool dimension(int? value) => value == null || value >= 1 && value <= 16384;
  bool bounded(int? value, int maximum) =>
      value == null || value >= 1 && value <= maximum;
  bool tokens(List<String> values, {int maximum = 32}) =>
      values.length <= maximum &&
      values.toSet().length == values.length &&
      values.every(optionalToken);
  return token(media.sourceId, maximum: 128) &&
      optionalToken(media.container) &&
      optionalToken(media.videoCodec) &&
      optionalToken(media.audioCodec) &&
      optionalToken(media.subtitleCodec) &&
      bounded(media.bitrateBps, 1000000000) &&
      dimension(media.width) &&
      dimension(media.height) &&
      media.transcodeReasons.length <= 16 &&
      media.transcodeReasons.toSet().length == media.transcodeReasons.length &&
      tokens(receiver.videoCodecs) &&
      tokens(receiver.audioCodecs) &&
      tokens(receiver.subtitleFormats) &&
      receiver.hdrTypes.length <= 8 &&
      receiver.hdrTypes.toSet().length == receiver.hdrTypes.length &&
      dimension(receiver.maxWidth) &&
      dimension(receiver.maxHeight) &&
      bounded(network.downstreamKbps, 1000000000);
}
