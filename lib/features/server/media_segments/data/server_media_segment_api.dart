import 'dart:math';

import '../../data/larenor_server_api.dart';
import '../../domain/server_models.dart';
import '../domain/server_media_segment_models.dart';

/// A one-shot, read-only segment lookup. There is deliberately no retry: the
/// caller must bind every response to its current source and item epochs.
final class ServerMediaSegmentApi {
  ServerMediaSegmentApi(this.api, this.session, {String Function()? requestId})
    : _requestId = requestId ?? _randomId;

  final LarenorServerApi api;
  final ServerSession session;
  final String Function() _requestId;

  Future<ServerMediaSegmentResult> read(
    ServerMediaSegmentSource source, {
    required int sourceEpoch,
    required int itemEpoch,
  }) async {
    if (session.context == null || session.sessionFamilyId == null) {
      throw const LarenorServerException('invalid_session');
    }
    final requestId = _requestId();
    if (!RegExp(r'^[0-9a-f]{32}$').hasMatch(requestId) ||
        sourceEpoch < 0 ||
        itemEpoch < 0) {
      throw const LarenorServerException('invalid_request');
    }
    final response = await api.request(
      'POST',
      '/media/playback/segments',
      token: session.accessToken,
      body: source.request(requestId),
    );
    return ServerMediaSegmentResult.fromJson(
      response,
      session: session,
      source: source,
      requestId: requestId,
      sourceEpoch: sourceEpoch,
      itemEpoch: itemEpoch,
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
