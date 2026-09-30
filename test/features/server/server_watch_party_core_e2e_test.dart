import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/server/data/larenor_server_api.dart';
import 'package:larenor/features/server/domain/server_models.dart';
import 'package:larenor/features/server/media_catalog/domain/server_media_catalog_models.dart';
import 'package:larenor/features/server/media_segments/domain/server_media_segment_models.dart';
import 'package:larenor/features/server/watch_parties/data/server_watch_party_api.dart';
import 'package:larenor/features/server/watch_parties/domain/server_watch_party_models.dart';

const _coreId = '11111111111111111111111111111111';
const _homeId = '22222222222222222222222222222222';
const _roomId = '33333333333333333333333333333333';
const _installationId = '44444444444444444444444444444444';
const _itemId = '55555555555555555555555555555555';
const _leaderId = '66666666666666666666666666666666';
const _followerId = '77777777777777777777777777777777';
const _inviteCode = '88888888888888888888888888888888';
const _leaderToken = 'leader_loopback_access_token_1234567890';
const _followerToken = 'follower_loopback_access_token_12345678';

final class _MemberState {
  _MemberState({required this.accountId, required this.leader});

  final String accountId;
  int revision = 1;
  bool leader;
  bool connected = true;
  Map<String, Object?>? target;
  Map<String, Object?>? playback;
}

final class _WatchPartyCore {
  _WatchPartyCore._(this.server) {
    unawaited(_serve());
  }

  final HttpServer server;
  final members = <String, _MemberState>{};
  final requests = <Map<String, Object?>>[];
  int revision = 1;
  int commandRevision = 1;
  String commandAction = 'pause';
  int commandPositionMs = 0;

  String get baseUrl => 'http://127.0.0.1:${server.port}';

  static Future<_WatchPartyCore> start() async =>
      _WatchPartyCore._(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));

  Future<void> _serve() async {
    await for (final request in server) {
      unawaited(_handle(request).catchError((Object _) {}));
    }
  }

  Future<void> _handle(HttpRequest request) async {
    final token = request.headers.value(HttpHeaders.authorizationHeader);
    final accountId = switch (token) {
      'Bearer $_leaderToken' => _leaderId,
      'Bearer $_followerToken' => _followerId,
      _ => null,
    };
    if (accountId == null) {
      return _json(request, {
        'error': {'code': 'invalid_session'},
      }, 401);
    }
    final raw = await utf8.decoder.bind(request).join();
    final body = raw.isEmpty
        ? <String, Object?>{}
        : Map<String, Object?>.from(jsonDecode(raw) as Map);
    requests.add({
      'method': request.method,
      'path': request.uri.path,
      'body': body,
    });
    final path = request.uri.path;

    if (request.method == 'POST' && path == '/api/v1/media/watch-parties') {
      expect(accountId, _leaderId);
      expect(body['itemId'], _itemId);
      expect(body['toleranceMs'], 750);
      members[_leaderId] = _MemberState(accountId: _leaderId, leader: true);
      return _json(request, {
        'snapshot': _snapshot(accountId),
        'inviteCode': _inviteCode,
      }, 201);
    }
    if (path == '/api/v1/media/watch-parties/$_roomId/join') {
      if (!_expected(body, 'expectedRoomRevision')) return _conflict(request);
      final member = members.putIfAbsent(
        accountId,
        () => _MemberState(accountId: accountId, leader: false),
      );
      if (!member.connected) {
        member.connected = true;
        member.revision++;
      }
      revision++;
      return _json(request, {'snapshot': _snapshot(accountId)});
    }
    if (path == '/api/v1/media/watch-parties/$_roomId' &&
        request.method == 'GET') {
      return _json(request, {'snapshot': _snapshot(accountId)});
    }
    if (path == '/api/v1/media/watch-parties/$_roomId/reports') {
      if (!_expected(body, 'expectedRoomRevision')) return _conflict(request);
      final member = members[accountId]!;
      if (body['expectedParticipantRevision'] != member.revision) {
        return _conflict(request);
      }
      member.target = Map<String, Object?>.from(body['target']! as Map);
      member.playback = Map<String, Object?>.from(body['playback']! as Map);
      member.revision++;
      revision++;
      return _json(request, {'snapshot': _snapshot(accountId)});
    }
    if (path == '/api/v1/media/watch-parties/$_roomId/commands') {
      if (!_expected(body, 'expectedRoomRevision')) return _conflict(request);
      final leader = members[accountId]!;
      if (!leader.leader || body['expectedLeaderRevision'] != leader.revision) {
        return _conflict(request);
      }
      commandRevision++;
      commandAction = body['action'] == 'pause' ? 'pause' : 'play';
      commandPositionMs = body['positionMs']! as int;
      revision++;
      return _json(request, {'snapshot': _snapshot(accountId)});
    }
    if (path == '/api/v1/media/watch-parties/$_roomId/leave') {
      if (!_expected(body, 'expectedRoomRevision')) return _conflict(request);
      final member = members[accountId]!;
      if (body['expectedParticipantRevision'] != member.revision) {
        return _conflict(request);
      }
      member.connected = false;
      member.revision++;
      String? nextLeader;
      if (member.leader) {
        member.leader = false;
        final connected =
            members.values.where((candidate) => candidate.connected).toList()
              ..sort((a, b) => a.accountId.compareTo(b.accountId));
        if (connected.isNotEmpty) {
          connected.first.leader = true;
          nextLeader = connected.first.accountId;
        }
      }
      revision++;
      return _json(request, {
        'schemaVersion': 1,
        'state':
            nextLeader == null &&
                members.values.every((candidate) => !candidate.connected)
            ? 'closed'
            : 'active',
        'roomRevision': revision,
        'nextLeaderAccountId': nextLeader,
      });
    }
    return _json(request, {
      'error': {'code': 'not_found'},
    }, 404);
  }

  bool _expected(Map<String, Object?> body, String key) =>
      body[key] == revision;

  void _conflict(HttpRequest request) => _json(request, {
    'error': {'code': 'revision_conflict'},
  }, 409);

  Map<String, Object?> _snapshot(String actorId) {
    final actor = members[actorId];
    final unsupported =
        actor?.target?['canSeek'] == false &&
        commandAction == 'play' &&
        commandPositionMs > 0;
    return {
      'schemaVersion': 1,
      'authority': {
        'schemaVersion': 1,
        'coreId': _coreId,
        'homeId': _homeId,
        'roomId': _roomId,
        'installationId': _installationId,
        'installationRevision': 2,
        'snapshotRevision': 3,
        'jellyfinServiceRevision': 4,
        'itemId': _itemId,
        'mediaKey': 'movie:tmdb:603',
      },
      'revision': revision,
      'state': 'active',
      'leaderAccountId': members.values
          .singleWhere((value) => value.leader)
          .accountId,
      'expiresAt': 2000000000,
      'toleranceMs': 750,
      'command': {
        'schemaVersion': 1,
        'revision': commandRevision,
        'action': commandAction,
        'positionMs': commandPositionMs,
        'issuedAtMs': 1800000000000,
      },
      'participants': members.values
          .map(
            (member) => {
              'schemaVersion': 1,
              'accountId': member.accountId,
              'revision': member.revision,
              'isLeader': member.leader,
              'connected': member.connected,
              'target': member.target,
              'playback': member.playback,
              'lastSeenAt': 1800000000,
            },
          )
          .toList(),
      'directive': actor == null
          ? null
          : {
              'schemaVersion': 1,
              'commandRevision': commandRevision,
              'action': unsupported ? 'unsupported' : 'none',
              'positionMs': commandPositionMs,
              'skewMs': unsupported ? -120000 : 0,
              'toleranceMs': 750,
            },
    };
  }

  void _json(HttpRequest request, Object value, [int status = 200]) {
    request.response
      ..statusCode = status
      ..headers.contentType = ContentType.json
      ..write(jsonEncode(value))
      ..close();
  }
}

ServerSession _session(String baseUrl, String token, String accountId) =>
    ServerSession(
      endpoint: ServerEndpoint(baseUrl),
      accessToken: token,
      refreshToken: 'synthetic_loopback_refresh_token_123456789',
      expiresAt: DateTime.utc(2030),
      user: ServerUser(
        id: accountId,
        username: accountId == _leaderId ? 'leader' : 'follower',
        role: ServerRole.member,
        mustChangePassword: false,
      ),
      sessionFamilyId: accountId == _leaderId ? 'a' * 32 : 'b' * 32,
      context: ServerContext.fromJson({
        'schemaVersion': 1,
        'coreId': _coreId,
        'homeId': _homeId,
      }),
    );

ServerMediaSegmentSource _source() {
  final page = ServerMediaCatalogPage.fromJson(
    {
      'schemaVersion': 1,
      'installationId': _installationId,
      'installationRevision': 2,
      'snapshotRevision': 3,
      'jellyfinServiceRevision': 4,
      'offset': 0,
      'nextOffset': null,
      'total': 1,
      'items': const [
        {
          'itemId': _itemId,
          'mediaKey': 'movie:tmdb:603',
          'title': 'The Matrix',
          'mediaKind': 'movie',
          'runtimeSeconds': 8160,
        },
      ],
    },
    query: 'matrix',
    mediaKind: ServerMediaCatalogKind.movie,
  );
  return ServerMediaSegmentSource.fromCatalog(page, page.items.single);
}

String Function() _ids(int seed) {
  var value = seed;
  return () => (value++).toRadixString(16).padLeft(32, '0');
}

void main() {
  setUpAll(() => HttpOverrides.global = null);
  tearDownAll(() => HttpOverrides.global = null);

  test('two production Clients cross loopback Core through join, stale report, unsupported receiver and leave-rejoin', () async {
    final core = await _WatchPartyCore.start();
    addTearDown(() => core.server.close(force: true));
    final leaderSession = _session(core.baseUrl, _leaderToken, _leaderId);
    final followerSession = _session(core.baseUrl, _followerToken, _followerId);
    final leaderTransport = LarenorServerApi(endpoint: leaderSession.endpoint);
    final followerTransport = LarenorServerApi(
      endpoint: followerSession.endpoint,
    );
    addTearDown(leaderTransport.close);
    addTearDown(followerTransport.close);
    final leader = ServerWatchPartyApi(
      leaderTransport,
      leaderSession,
      requestId: _ids(1),
    );
    final follower = ServerWatchPartyApi(
      followerTransport,
      followerSession,
      requestId: _ids(100),
    );

    final created = await leader.create(
      _source(),
      expiresAt: DateTime.fromMillisecondsSinceEpoch(2000000000000),
      toleranceMs: 750,
    );
    var followerSnapshot = await follower.join(created.invitation);
    var leaderSnapshot = await leader.refresh(_roomId);
    leaderSnapshot = await leader.report(
      snapshot: leaderSnapshot,
      target: const ServerWatchPartyTarget(
        targetId: 'living-room',
        targetRevision: 1,
        canSeek: true,
        canPause: true,
      ),
      playback: const ServerWatchPartyPlayback(
        state: ServerWatchPartyPlaybackState.playing,
        positionMs: 120000,
        measuredRoundTripMs: 40,
      ),
    );

    await expectLater(
      follower.report(
        snapshot: followerSnapshot,
        target: const ServerWatchPartyTarget(
          targetId: 'kitchen-display',
          targetRevision: 1,
          canSeek: false,
          canPause: true,
        ),
        playback: const ServerWatchPartyPlayback(
          state: ServerWatchPartyPlaybackState.playing,
          positionMs: 0,
          measuredRoundTripMs: 85,
        ),
      ),
      throwsA(
        isA<LarenorServerException>().having(
          (error) => error.code,
          'code',
          'revision_conflict',
        ),
      ),
    );

    followerSnapshot = await follower.refresh(_roomId);
    followerSnapshot = await follower.report(
      snapshot: followerSnapshot,
      target: const ServerWatchPartyTarget(
        targetId: 'kitchen-display',
        targetRevision: 1,
        canSeek: false,
        canPause: true,
      ),
      playback: const ServerWatchPartyPlayback(
        state: ServerWatchPartyPlaybackState.playing,
        positionMs: 0,
        measuredRoundTripMs: 85,
      ),
    );
    leaderSnapshot = await leader.refresh(_roomId);
    await leader.command(
      snapshot: leaderSnapshot,
      action: 'seek',
      positionMs: 120000,
    );
    followerSnapshot = await follower.refresh(_roomId);
    expect(
      followerSnapshot.directive?.action,
      ServerWatchPartyDirectiveAction.unsupported,
    );

    await follower.leave(followerSnapshot);
    final rejoined = await follower.join(
      ServerWatchPartyInvitation(
        roomId: _roomId,
        roomRevision: core.revision,
        itemId: _itemId,
        inviteCode: _inviteCode,
      ),
    );
    expect(rejoined.self(_followerId).connected, isTrue);
    leaderSnapshot = await leader.refresh(_roomId);
    await leader.leave(leaderSnapshot);
    final promoted = await follower.refresh(_roomId);
    expect(promoted.leaderAccountId, _followerId);
    expect(promoted.self(_followerId).isLeader, isTrue);
  });
}
