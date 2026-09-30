import 'dart:math';

import '../../data/larenor_server_api.dart';
import '../../domain/server_models.dart';
import '../domain/server_longform_session_models.dart';
import '../domain/server_music_manager_models.dart';

class ServerLongformSessionApi {
  ServerLongformSessionApi(this.api, this.token, {String Function()? requestId})
    : _requestId = requestId ?? _randomId;

  final LarenorServerApi api;
  final String token;
  final String Function() _requestId;
  static const root = '/media/longform/sessions';

  Future<ServerLongformSession> open({
    required ServerMusicManager manager,
    required ServerMusicLongformItem item,
    bool takeover = false,
  }) async {
    final value = _session(
      await api.request(
        'POST',
        '$root/open',
        token: token,
        body: _authority(manager, item, takeover: takeover),
      ),
    );
    if (!value.matches(manager, item)) _invalidResponse();
    return value;
  }

  Future<ServerLongformSession> update({
    required ServerMusicManager manager,
    required ServerMusicLongformItem item,
    required ServerLongformSession session,
    required double positionSeconds,
    required ServerLongformPlaybackState playbackState,
    required List<ServerLongformBookmark> bookmarks,
    DateTime? sleepTimerEndsAt,
    ServerMusicReceiver? sleepTimerReceiver,
    bool takeover = false,
  }) async {
    if (!session.sameMedia(manager, item) ||
        positionSeconds < 0 ||
        !positionSeconds.isFinite ||
        positionSeconds > item.durationSeconds ||
        bookmarks.length > 64 ||
        bookmarks.map((value) => value.id).toSet().length != bookmarks.length ||
        bookmarks.any(
          (value) =>
              value.positionSeconds < 0 ||
              value.positionSeconds > item.durationSeconds,
        ) ||
        (playbackState == ServerLongformPlaybackState.ended &&
            positionSeconds != item.durationSeconds) ||
        (sleepTimerEndsAt == null) != (sleepTimerReceiver == null)) {
      _invalidRequest();
    }
    final sleepQueue = sleepTimerReceiver == null
        ? null
        : manager.queueFor(sleepTimerReceiver);
    if (sleepTimerReceiver != null &&
        (!manager.receivers.any((value) => value.id == sleepTimerReceiver.id) ||
            !sleepTimerReceiver.available ||
            !sleepTimerReceiver.enabled ||
            !sleepTimerReceiver.supports(ServerMusicOperation.pause) ||
            sleepQueue == null ||
            !sleepQueue.active ||
            sleepQueue.currentItemUri != item.uri)) {
      _invalidRequest();
    }
    final body = _authority(manager, item, takeover: takeover)
      ..addAll({
        'expectedRevision': session.revision,
        'positionSeconds': positionSeconds,
        'playbackState': playbackState.name,
        'sleepTimerEndsAt': sleepTimerEndsAt == null
            ? null
            : sleepTimerEndsAt.toUtc().millisecondsSinceEpoch ~/ 1000,
        'sleepTimerTarget': sleepTimerReceiver == null
            ? null
            : {
                'targetId': sleepTimerReceiver.id,
                'expectedProvider': sleepTimerReceiver.provider,
                'expectedTargetKind': sleepTimerReceiver.kind,
                'expectedQueueId': sleepTimerReceiver.queueId,
                'expectedGroupMembers': sleepTimerReceiver.groupMembers,
              },
        'bookmarks': bookmarks.map((value) => value.toJson()).toList(),
      });
    final value = _session(
      await api.request(
        'POST',
        '$root/${session.id}',
        token: token,
        body: body,
      ),
    );
    if (!value.matches(manager, item) || value.revision <= session.revision) {
      _invalidResponse();
    }
    return value;
  }

  Map<String, dynamic> _authority(
    ServerMusicManager manager,
    ServerMusicLongformItem item, {
    required bool takeover,
  }) {
    final requestId = _requestId();
    if (!RegExp(r'^[a-f0-9]{32}$').hasMatch(requestId) ||
        !manager.providers.any(
          (provider) => provider.instanceId == item.providerInstanceId,
        )) {
      _invalidRequest();
    }
    return {
      'schemaVersion': 2,
      'requestId': requestId,
      'installationId': manager.installationId,
      'expectedInstallationRevision': manager.installationRevision,
      'expectedCoreRevision': manager.coreRevision,
      'expectedManagerRevision': manager.revision,
      'limit': 25,
      'mediaUri': item.uri,
      'providerInstanceId': item.providerInstanceId,
      'takeover': takeover,
    };
  }

  ServerLongformSession _session(Object? response) {
    final map = serverObject(response);
    if (map.length != 1 || !map.containsKey('session')) _invalidResponse();
    return ServerLongformSession.fromJson(map['session']);
  }
}

String _randomId() {
  final random = Random.secure();
  return List.generate(
    16,
    (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
}

Never _invalidRequest() =>
    throw const LarenorServerException('invalid_request');
Never _invalidResponse() =>
    throw const LarenorServerException('invalid_response');
