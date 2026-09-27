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
      RegExp(r'^[A-Za-z0-9][A-Za-z0-9._,+-]*$').hasMatch(value);
  bool optionalToken(String? value) => value == null || token(value);
  bool dimension(int? value) => value == null || value >= 1 && value <= 32768;
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
      (media.width == null) == (media.height == null) &&
      media.transcodeReasons.length <= 10 &&
      media.transcodeReasons.toSet().length == media.transcodeReasons.length &&
      tokens(receiver.videoCodecs) &&
      tokens(receiver.audioCodecs) &&
      tokens(receiver.subtitleFormats) &&
      receiver.hdrTypes.length <= 6 &&
      receiver.hdrTypes.toSet().length == receiver.hdrTypes.length &&
      dimension(receiver.maxWidth) &&
      dimension(receiver.maxHeight) &&
      (receiver.maxWidth == null) == (receiver.maxHeight == null) &&
      bounded(network.downstreamKbps, 10000000) &&
      _coherentRequest(request);
}

bool _coherentRequest(CorePlaybackQualityRequest request) {
  final media = request.media;
  final receiver = request.receiver;
  final network = request.network;
  final mediaDetails = <Object?>[
    media.container,
    media.videoCodec,
    media.audioCodec,
    media.subtitleCodec,
    media.bitrateBps,
    media.width,
    media.height,
    media.hdr,
  ];
  if (media.state == CorePlaybackEvidenceState.unknown) {
    if (mediaDetails.any((value) => value != null) ||
        media.serverDecision != CorePlaybackMethod.unknown ||
        media.transcodeReasons.isNotEmpty) {
      return false;
    }
  } else if (mediaDetails.every((value) => value == null) &&
      media.serverDecision == CorePlaybackMethod.unknown) {
    return false;
  }
  if ((media.serverDecision == CorePlaybackMethod.directPlay ||
          media.serverDecision == CorePlaybackMethod.unknown) &&
      media.transcodeReasons.isNotEmpty) {
    return false;
  }
  final receiverHasEvidence =
      receiver.videoCodecs.isNotEmpty ||
      receiver.audioCodecs.isNotEmpty ||
      receiver.subtitleFormats.isNotEmpty ||
      receiver.hdrTypes.isNotEmpty ||
      receiver.maxWidth != null;
  if (receiver.state == CorePlaybackEvidenceState.unknown
      ? receiverHasEvidence
      : !receiverHasEvidence) {
    return false;
  }
  final networkHasEvidence =
      network.transport != null ||
      network.downstreamKbps != null ||
      network.metered != null;
  return network.state == CorePlaybackEvidenceState.unknown
      ? !networkHasEvidence
      : networkHasEvidence;
}
