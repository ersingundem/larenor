import 'dart:math';

import '../../data/larenor_server_api.dart';
import '../../domain/server_models.dart';
import '../../music_manager/domain/server_music_manager_models.dart';
import '../domain/server_party_dj_models.dart';
import 'server_party_dj_recovery_store.dart';

final class ServerPartyDjCreateResult {
  const ServerPartyDjCreateResult(this.room, this.invitation);
  final ServerPartyDjRoom room;
  final ServerPartyDjInvitation invitation;
}

final class ServerPartyDjApi {
  ServerPartyDjApi(this.api, this.session, {String Function()? requestId})
    : _requestId = requestId ?? _randomId;

  static const root = '/media/party-dj/rooms';
  final LarenorServerApi api;
  final ServerSession session;
  final String Function() _requestId;

  Future<ServerPartyDjCreateResult> create({
    required ServerMusicManager manager,
    required ServerMusicReceiver receiver,
    required DateTime expiresAt,
    int proposalLimitPerUser = 3,
    int skipQuorumPercent = 60,
    bool Function()? current,
  }) async {
    if (!receiver.available ||
        !receiver.enabled ||
        !receiver.supports(ServerMusicOperation.queueAdd) ||
        !receiver.capabilities.contains('next_previous') ||
        !manager.receivers.any((item) => identical(item, receiver)) ||
        proposalLimitPerUser < 1 ||
        proposalLimitPerUser > 3 ||
        skipQuorumPercent < 50 ||
        skipQuorumPercent > 100 ||
        !expiresAt.isAfter(DateTime.now()) ||
        expiresAt.difference(DateTime.now()) > const Duration(days: 1)) {
      throw const LarenorServerException('invalid_request');
    }
    _current(current);
    final response = _response(
      await api.request(
        'POST',
        root,
        token: session.accessToken,
        body: {
          'schemaVersion': 1,
          'requestId': _id(),
          'installationId': manager.installationId,
          'expectedInstallationRevision': manager.installationRevision,
          'expectedCoreRevision': manager.coreRevision,
          'expectedManagerRevision': manager.revision,
          'expectedPlayerRevision': manager.revision,
          'targetId': receiver.id,
          'expectedProvider': receiver.provider,
          'expectedTargetKind': receiver.kind,
          'expectedQueueId': receiver.queueId,
          'expectedGroupMembers': receiver.groupMembers,
          'expiresAt': expiresAt.toUtc().millisecondsSinceEpoch ~/ 1000,
          'proposalLimitPerUser': proposalLimitPerUser,
          'skipQuorumPercent': skipQuorumPercent,
        },
      ),
      {'room', 'inviteCode'},
    );
    _current(current);
    final room = ServerPartyDjRoom.fromJson(response['room'], session);
    if (!room.authority.matches(manager, receiver)) _invalidResponse();
    final inviteCode = response['inviteCode'];
    if (inviteCode is! String ||
        !RegExp(r'^[0-9a-f]{32}$').hasMatch(inviteCode)) {
      _invalidResponse();
    }
    return ServerPartyDjCreateResult(
      room,
      ServerPartyDjInvitation(
        roomId: room.id,
        roomRevision: room.revision,
        inviteCode: inviteCode,
      ),
    );
  }

  Future<ServerPartyDjRoom> join(
    ServerPartyDjInvitation invitation, {
    bool Function()? current,
  }) => _room(
    'POST',
    '$root/${invitation.roomId}/join',
    body: {
      'schemaVersion': 1,
      'requestId': _id(),
      'inviteCode': invitation.inviteCode,
      'expectedRoomRevision': invitation.roomRevision,
    },
    expectedId: invitation.roomId,
    current: current,
  );

  Future<ServerPartyDjRoom> read(String roomId, {bool Function()? current}) =>
      _room(
        'GET',
        '$root/${_pathId(roomId)}',
        expectedId: roomId,
        current: current,
      );

  Future<ServerPartyDjRoom> heartbeat(
    ServerPartyDjRoom room, {
    bool Function()? current,
  }) => _room(
    'POST',
    '$root/${room.id}/heartbeat',
    body: {
      'schemaVersion': 1,
      'requestId': _id(),
      'expectedRoomRevision': room.revision,
      'expectedParticipantRevision': room.currentParticipantRevision,
    },
    expectedId: room.id,
    current: current,
  );

  Future<void> leave(ServerPartyDjRoom room, {bool Function()? current}) async {
    _current(current);
    final response = _response(
      await api.request(
        'POST',
        '$root/${room.id}/leave',
        token: session.accessToken,
        body: {
          'schemaVersion': 1,
          'requestId': _id(),
          'expectedRoomRevision': room.revision,
          'expectedParticipantRevision': room.currentParticipantRevision,
        },
      ),
      {'schemaVersion', 'state', 'roomRevision', 'nextHostAccountId'},
    );
    _current(current);
    final revision = response['roomRevision'];
    final nextHost = response['nextHostAccountId'];
    if (response['schemaVersion'] != 1 ||
        response['state'] != 'active' && response['state'] != 'closed' ||
        revision is! int ||
        revision <= room.revision ||
        nextHost != null &&
            (nextHost is! String ||
                !RegExp(r'^[0-9a-f]{32}$').hasMatch(nextHost))) {
      _invalidResponse();
    }
  }

  Future<ServerPartyDjRoom> propose({
    required ServerPartyDjRoom room,
    required ServerMusicCatalogItem item,
    required ServerMusicProviderBinding provider,
    required String catalogQuery,
    bool Function()? current,
  }) => _room(
    'POST',
    '$root/${room.id}/proposals',
    body: {
      'schemaVersion': 1,
      'requestId': _id(),
      'expectedRoomRevision': room.revision,
      'catalogRequestId': _id(),
      'catalogQuery': catalogQuery,
      'mediaUri': item.uri,
      'name': item.name,
      'providerSetupId': provider.setupId,
      'expectedProviderRevision': provider.revision,
      'providerDomain': provider.domain,
      'providerInstanceId': item.providerInstanceId,
    },
    expectedId: room.id,
    current: current,
  );

  Future<ServerPartyDjRoom> vote({
    required ServerPartyDjRoom room,
    required ServerPartyDjProposal proposal,
    required bool selected,
    bool Function()? current,
  }) => _room(
    'POST',
    '$root/${room.id}/proposals/${proposal.id}/votes',
    body: {
      'schemaVersion': 1,
      'requestId': _id(),
      'expectedRoomRevision': room.revision,
      'expectedProposalRevision': proposal.revision,
      'vote': selected ? 'up' : 'remove',
    },
    expectedId: room.id,
    current: current,
  );

  Future<ServerPartyDjRoom> decide({
    required ServerPartyDjRoom room,
    required ServerPartyDjProposal proposal,
    required bool approve,
    bool Function()? current,
  }) => _room(
    'POST',
    '$root/${room.id}/proposals/${proposal.id}/decision',
    body: {
      'schemaVersion': 1,
      'requestId': _id(),
      'expectedRoomRevision': room.revision,
      'expectedProposalRevision': proposal.revision,
      'decision': approve ? 'approve' : 'reject',
      'expectedPlayerRevision': approve ? room.authority.playerRevision : null,
    },
    expectedId: room.id,
    current: current,
  );

  Future<ServerPartyDjRoom> dismissProposal({
    required ServerPartyDjRoom room,
    required ServerPartyDjProposal proposal,
    bool Function()? current,
  }) => _room(
    'POST',
    '$root/${room.id}/proposals/${proposal.id}/dismiss',
    body: {
      'schemaVersion': 1,
      'requestId': _id(),
      'expectedRoomRevision': room.revision,
      'expectedProposalRevision': proposal.revision,
    },
    expectedId: room.id,
    current: current,
  );

  Future<ServerPartyDjRoom> voteToSkip(
    ServerPartyDjRoom room, {
    bool Function()? current,
  }) => _room(
    'POST',
    '$root/${room.id}/skip-votes',
    body: {
      'schemaVersion': 1,
      'requestId': _id(),
      'expectedRoomRevision': room.revision,
      'expectedParticipantRevision': room.currentParticipantRevision,
      'expectedPlayerRevision': room.authority.playerRevision,
    },
    expectedId: room.id,
    current: current,
  );

  Future<ServerPartyDjRoom> dismissSkip(
    ServerPartyDjRoom room, {
    bool Function()? current,
  }) => _room(
    'POST',
    '$root/${room.id}/skip-votes/dismiss',
    body: {
      'schemaVersion': 1,
      'requestId': _id(),
      'expectedRoomRevision': room.revision,
      'expectedParticipantRevision': room.currentParticipantRevision,
    },
    expectedId: room.id,
    current: current,
  );

  Future<ServerPartyDjRoom> executePendingEffect(
    ServerPartyDjPendingEffect effect, {
    bool Function()? current,
  }) {
    final roomId = effect.roomId;
    if (roomId == null || effect.kind == ServerPartyDjEffectKind.create) {
      throw const LarenorServerException('invalid_request');
    }
    return _room(
      'POST',
      switch (effect.kind) {
        ServerPartyDjEffectKind.join => '$root/$roomId/join',
        ServerPartyDjEffectKind.proposal => '$root/$roomId/proposals',
        ServerPartyDjEffectKind.decision =>
          '$root/$roomId/proposals/${effect.proposalId}/decision',
        ServerPartyDjEffectKind.skip => '$root/$roomId/skip-votes',
        ServerPartyDjEffectKind.create => throw const LarenorServerException(
          'invalid_request',
        ),
      },
      body: effect.body,
      expectedId: roomId,
      current: current,
    );
  }

  Future<ServerPartyDjCreateResult> executePendingCreate(
    ServerPartyDjPendingEffect effect, {
    bool Function()? current,
  }) async {
    if (effect.kind != ServerPartyDjEffectKind.create ||
        effect.roomId != null) {
      throw const LarenorServerException('invalid_request');
    }
    _current(current);
    final response = _response(
      await api.request(
        'POST',
        root,
        token: session.accessToken,
        body: effect.body,
      ),
      {'room', 'inviteCode'},
    );
    _current(current);
    final room = ServerPartyDjRoom.fromJson(response['room'], session);
    final authority = room.authority;
    final body = effect.body;
    final expectedMembers = body['expectedGroupMembers'];
    if (authority.installationId != body['installationId'] ||
        authority.installationRevision !=
            body['expectedInstallationRevision'] ||
        authority.coreRevision != body['expectedCoreRevision'] ||
        authority.managerRevision != body['expectedManagerRevision'] ||
        authority.playerRevision != body['expectedPlayerRevision'] ||
        authority.targetId != body['targetId'] ||
        authority.provider != body['expectedProvider'] ||
        authority.targetKind != body['expectedTargetKind'] ||
        authority.queueId != body['expectedQueueId'] ||
        expectedMembers is! List ||
        expectedMembers.length != authority.groupMembers.length ||
        !List.generate(
          expectedMembers.length,
          (index) => expectedMembers[index] == authority.groupMembers[index],
        ).every((matches) => matches)) {
      _invalidResponse();
    }
    final inviteCode = response['inviteCode'];
    if (inviteCode is! String ||
        !RegExp(r'^[0-9a-f]{32}$').hasMatch(inviteCode)) {
      _invalidResponse();
    }
    return ServerPartyDjCreateResult(
      room,
      ServerPartyDjInvitation(
        roomId: room.id,
        roomRevision: room.revision,
        inviteCode: inviteCode,
      ),
    );
  }

  Future<ServerPartyDjRoom> _room(
    String method,
    String path, {
    Map<String, Object?>? body,
    required String expectedId,
    bool Function()? current,
  }) async {
    _current(current);
    final response = _response(
      await api.request(method, path, token: session.accessToken, body: body),
      {'room'},
    );
    _current(current);
    final value = ServerPartyDjRoom.fromJson(response['room'], session);
    if (value.id != expectedId) _invalidResponse();
    return value;
  }

  String _id() {
    final value = _requestId();
    if (!RegExp(r'^[0-9a-f]{32}$').hasMatch(value)) {
      throw const LarenorServerException('invalid_request');
    }
    return value;
  }

  static String _pathId(String value) {
    if (!RegExp(r'^[0-9a-f]{32}$').hasMatch(value)) {
      throw const LarenorServerException('invalid_request');
    }
    return value;
  }

  static Map<String, dynamic> _response(Object? raw, Set<String> keys) {
    final value = serverObject(raw);
    if (value.length != keys.length || !value.keys.every(keys.contains)) {
      _invalidResponse();
    }
    return value;
  }

  static void _current(bool Function()? current) {
    if (current != null && !current()) {
      throw const LarenorServerException('retired');
    }
  }

  static Never _invalidResponse() =>
      throw const LarenorServerException('invalid_response');

  static String _randomId() {
    final random = Random.secure();
    return List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }
}
