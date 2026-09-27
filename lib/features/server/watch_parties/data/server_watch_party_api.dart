import 'dart:math';

import '../../data/larenor_server_api.dart';
import '../../domain/server_models.dart';
import '../../media_segments/domain/server_media_segment_models.dart';
import '../domain/server_watch_party_models.dart';

final class ServerWatchPartyCreateResult {
  const ServerWatchPartyCreateResult(this.snapshot, this.invitation);
  final ServerWatchPartySnapshot snapshot;
  final ServerWatchPartyInvitation invitation;
}

final class ServerWatchPartyApi {
  ServerWatchPartyApi(this.api, this.session, {String Function()? requestId})
    : _requestId = requestId ?? _randomId;

  final LarenorServerApi api;
  final ServerSession session;
  final String Function() _requestId;

  Future<ServerWatchPartyCreateResult> create(
    ServerMediaSegmentSource source, {
    required DateTime expiresAt,
    int toleranceMs = 1500,
  }) async {
    final requestId = _id();
    final response = serverObject(
      await api.request(
        'POST',
        '/media/watch-parties',
        token: session.accessToken,
        body: {
          ...source.request(requestId),
          'expiresAt': expiresAt.millisecondsSinceEpoch ~/ 1000,
          'toleranceMs': toleranceMs,
        },
      ),
    );
    if (response.length != 2 ||
        !response.containsKey('snapshot') ||
        !response.containsKey('inviteCode')) {
      throw const LarenorServerException('invalid_response');
    }
    final snapshot = ServerWatchPartySnapshot.fromJson(
      response['snapshot'],
      session: session,
    );
    if (snapshot.itemId != source.itemId) {
      throw const LarenorServerException('invalid_response');
    }
    final code = response['inviteCode'];
    if (code is! String || !RegExp(r'^[0-9a-f]{32}$').hasMatch(code)) {
      throw const LarenorServerException('invalid_response');
    }
    return ServerWatchPartyCreateResult(
      snapshot,
      ServerWatchPartyInvitation(
        roomId: snapshot.roomId,
        roomRevision: snapshot.revision,
        itemId: snapshot.itemId,
        inviteCode: code,
      ),
    );
  }

  Future<ServerWatchPartySnapshot> join(
    ServerWatchPartyInvitation invitation,
  ) => _snapshot(
    'POST',
    '/media/watch-parties/${invitation.roomId}/join',
    body: {
      'schemaVersion': 1,
      'requestId': _id(),
      'inviteCode': invitation.inviteCode,
      'expectedRoomRevision': invitation.roomRevision,
    },
  );

  Future<ServerWatchPartySnapshot> refresh(String roomId) =>
      _snapshot('GET', '/media/watch-parties/${_room(roomId)}');

  Future<ServerWatchPartySnapshot> report({
    required ServerWatchPartySnapshot snapshot,
    required ServerWatchPartyTarget target,
    required ServerWatchPartyPlayback playback,
  }) => _snapshot(
    'POST',
    '/media/watch-parties/${snapshot.roomId}/reports',
    body: {
      'schemaVersion': 1,
      'requestId': _id(),
      'expectedRoomRevision': snapshot.revision,
      'expectedParticipantRevision': snapshot.self(session.user.id).revision,
      'target': target.toJson(),
      'playback': playback.toJson(),
    },
  );

  Future<ServerWatchPartySnapshot> command({
    required ServerWatchPartySnapshot snapshot,
    required String action,
    required int positionMs,
  }) => _snapshot(
    'POST',
    '/media/watch-parties/${snapshot.roomId}/commands',
    body: {
      'schemaVersion': 1,
      'requestId': _id(),
      'expectedRoomRevision': snapshot.revision,
      'expectedLeaderRevision': snapshot.self(session.user.id).revision,
      'action': action,
      'positionMs': positionMs,
    },
  );

  Future<ServerWatchPartySnapshot> transfer({
    required ServerWatchPartySnapshot snapshot,
    required ServerWatchPartyMember nextLeader,
  }) => _snapshot(
    'POST',
    '/media/watch-parties/${snapshot.roomId}/leader',
    body: {
      'schemaVersion': 1,
      'requestId': _id(),
      'expectedRoomRevision': snapshot.revision,
      'expectedLeaderRevision': snapshot.self(session.user.id).revision,
      'nextLeaderAccountId': nextLeader.accountId,
      'expectedNextLeaderRevision': nextLeader.revision,
    },
  );

  Future<void> leave(ServerWatchPartySnapshot snapshot) async {
    final response = serverObject(
      await api.request(
        'POST',
        '/media/watch-parties/${snapshot.roomId}/leave',
        token: session.accessToken,
        body: {
          'schemaVersion': 1,
          'requestId': _id(),
          'expectedRoomRevision': snapshot.revision,
          'expectedParticipantRevision': snapshot
              .self(session.user.id)
              .revision,
        },
      ),
    );
    if (response.length != 4 ||
        response['schemaVersion'] != 1 ||
        response['state'] != 'active' && response['state'] != 'closed' ||
        response['roomRevision'] is! int ||
        response['nextLeaderAccountId'] != null &&
            response['nextLeaderAccountId'] is! String) {
      throw const LarenorServerException('invalid_response');
    }
  }

  Future<ServerWatchPartySnapshot> _snapshot(
    String method,
    String path, {
    Map<String, Object?>? body,
  }) async {
    final response = serverObject(
      await api.request(method, path, token: session.accessToken, body: body),
    );
    if (response.length != 1 || !response.containsKey('snapshot')) {
      throw const LarenorServerException('invalid_response');
    }
    return ServerWatchPartySnapshot.fromJson(
      response['snapshot'],
      session: session,
    );
  }

  String _id() {
    final value = _requestId();
    if (!RegExp(r'^[0-9a-f]{32}$').hasMatch(value)) {
      throw const LarenorServerException('invalid_request');
    }
    return value;
  }

  static String _room(String value) {
    if (!RegExp(r'^[0-9a-f]{32}$').hasMatch(value)) {
      throw const LarenorServerException('invalid_request');
    }
    return value;
  }

  static String _randomId() {
    final random = Random.secure();
    return List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }
}
