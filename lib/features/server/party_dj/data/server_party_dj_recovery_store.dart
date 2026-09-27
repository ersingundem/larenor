import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../../../core/configuration_writes.dart';
import '../../domain/server_models.dart';
import '../domain/server_party_dj_models.dart';

Never _invalid() => throw const FormatException('invalid_party_dj_recovery');

String _id(Object? value) {
  if (value is! String || !RegExp(r'^[a-f0-9]{32}$').hasMatch(value)) {
    _invalid();
  }
  return value;
}

int _revision(Object? value) {
  if (value is! int || value < 1 || value > 0x7ffffffffffffffe) _invalid();
  return value;
}

Map<String, dynamic> _object(Object? value, Set<String> keys) {
  if (value is! Map<String, dynamic> ||
      value.length != keys.length ||
      !value.keys.every(keys.contains)) {
    _invalid();
  }
  return value;
}

final class ServerPartyDjRecoveryScope {
  const ServerPartyDjRecoveryScope._({
    required this.coreId,
    required this.homeId,
    required this.accountId,
    required this.sessionFamilyId,
  });

  factory ServerPartyDjRecoveryScope.fromSession(ServerSession session) {
    final context = session.context;
    if (context == null || session.sessionFamilyId == null) {
      throw const LarenorServerException('invalid_session');
    }
    return ServerPartyDjRecoveryScope._(
      coreId: context.coreId,
      homeId: context.homeId,
      accountId: session.user.id,
      sessionFamilyId: session.sessionFamilyId!,
    );
  }

  final String coreId, homeId, accountId, sessionFamilyId;

  String get storageKey {
    final digest = sha256.convert(
      utf8.encode('$coreId\u0000$homeId\u0000$accountId\u0000$sessionFamilyId'),
    );
    return 'server_party_dj_recovery_v1_${digest.toString().substring(0, 32)}';
  }

  Map<String, Object> toJson() => {
    'coreId': coreId,
    'homeId': homeId,
    'accountId': accountId,
    'sessionFamilyId': sessionFamilyId,
  };

  bool matches(Object? raw) {
    try {
      final value = _object(raw, {
        'coreId',
        'homeId',
        'accountId',
        'sessionFamilyId',
      });
      return value['coreId'] == coreId &&
          value['homeId'] == homeId &&
          value['accountId'] == accountId &&
          value['sessionFamilyId'] == sessionFamilyId;
    } on FormatException {
      return false;
    }
  }
}

enum ServerPartyDjEffectKind { create, join, proposal, decision, skip }

final class ServerPartyDjPendingEffect {
  const ServerPartyDjPendingEffect._({
    required this.kind,
    required this.roomId,
    required this.proposalId,
    required this.requestId,
    required this.body,
  });

  factory ServerPartyDjPendingEffect.create({
    required String requestId,
    required String installationId,
    required int installationRevision,
    required int coreRevision,
    required int managerRevision,
    required int playerRevision,
    required String targetId,
    required String provider,
    required String targetKind,
    required String? queueId,
    required List<String> groupMembers,
    required DateTime expiresAt,
    int proposalLimitPerUser = 3,
    int skipQuorumPercent = 60,
  }) => ServerPartyDjPendingEffect._(
    kind: ServerPartyDjEffectKind.create,
    roomId: null,
    proposalId: null,
    requestId: _id(requestId),
    body: Map.unmodifiable({
      'schemaVersion': 1,
      'requestId': requestId,
      'installationId': _id(installationId),
      'expectedInstallationRevision': installationRevision,
      'expectedCoreRevision': coreRevision,
      'expectedManagerRevision': managerRevision,
      'expectedPlayerRevision': playerRevision,
      'targetId': targetId,
      'expectedProvider': provider,
      'expectedTargetKind': targetKind,
      'expectedQueueId': queueId,
      'expectedGroupMembers': List<String>.unmodifiable(groupMembers),
      'expiresAt': expiresAt.toUtc().millisecondsSinceEpoch ~/ 1000,
      'proposalLimitPerUser': proposalLimitPerUser,
      'skipQuorumPercent': skipQuorumPercent,
    }),
  );

  factory ServerPartyDjPendingEffect.join({
    required ServerPartyDjInvitation invitation,
    required String requestId,
  }) => ServerPartyDjPendingEffect._(
    kind: ServerPartyDjEffectKind.join,
    roomId: _id(invitation.roomId),
    proposalId: null,
    requestId: _id(requestId),
    body: Map.unmodifiable({
      'schemaVersion': 1,
      'requestId': requestId,
      'inviteCode': _id(invitation.inviteCode),
      'expectedRoomRevision': invitation.roomRevision,
    }),
  );

  factory ServerPartyDjPendingEffect.decision({
    required String roomId,
    required String proposalId,
    required String requestId,
    required int roomRevision,
    required int proposalRevision,
    required bool approve,
    required int playerRevision,
  }) => ServerPartyDjPendingEffect._(
    kind: ServerPartyDjEffectKind.decision,
    roomId: _id(roomId),
    proposalId: _id(proposalId),
    requestId: _id(requestId),
    body: Map.unmodifiable({
      'schemaVersion': 1,
      'requestId': requestId,
      'expectedRoomRevision': roomRevision,
      'expectedProposalRevision': proposalRevision,
      'decision': approve ? 'approve' : 'reject',
      'expectedPlayerRevision': approve ? playerRevision : null,
    }),
  );

  factory ServerPartyDjPendingEffect.proposal({
    required String roomId,
    required String requestId,
    required String catalogRequestId,
    required int roomRevision,
    required String catalogQuery,
    required String mediaUri,
    required String name,
    required String providerSetupId,
    required int providerRevision,
    required String providerDomain,
    required String providerInstanceId,
  }) => ServerPartyDjPendingEffect._(
    kind: ServerPartyDjEffectKind.proposal,
    roomId: _id(roomId),
    proposalId: null,
    requestId: _id(requestId),
    body: Map.unmodifiable({
      'schemaVersion': 1,
      'requestId': requestId,
      'catalogRequestId': _id(catalogRequestId),
      'expectedRoomRevision': roomRevision,
      'catalogQuery': catalogQuery,
      'mediaUri': mediaUri,
      'name': name,
      'providerSetupId': _id(providerSetupId),
      'expectedProviderRevision': providerRevision,
      'providerDomain': providerDomain,
      'providerInstanceId': providerInstanceId,
    }),
  );

  factory ServerPartyDjPendingEffect.skip({
    required String roomId,
    required String requestId,
    required int roomRevision,
    required int participantRevision,
    required int playerRevision,
  }) => ServerPartyDjPendingEffect._(
    kind: ServerPartyDjEffectKind.skip,
    roomId: _id(roomId),
    proposalId: null,
    requestId: _id(requestId),
    body: Map.unmodifiable({
      'schemaVersion': 1,
      'requestId': requestId,
      'expectedRoomRevision': roomRevision,
      'expectedParticipantRevision': participantRevision,
      'expectedPlayerRevision': playerRevision,
    }),
  );

  factory ServerPartyDjPendingEffect.fromJson(Object? raw) {
    final value = _object(raw, {
      'kind',
      'roomId',
      'proposalId',
      'requestId',
      'body',
    });
    final roomIdRaw = value['roomId'];
    final roomId = roomIdRaw == null ? null : _id(roomIdRaw);
    final requestId = _id(value['requestId']);
    final bodyRaw = value['body'];
    if (bodyRaw is! Map<String, dynamic> ||
        bodyRaw['schemaVersion'] != 1 ||
        bodyRaw['requestId'] != requestId) {
      _invalid();
    }
    switch (value['kind']) {
      case 'create':
        if (roomId != null || value['proposalId'] != null) _invalid();
        final body = _object(bodyRaw, {
          'schemaVersion',
          'requestId',
          'installationId',
          'expectedInstallationRevision',
          'expectedCoreRevision',
          'expectedManagerRevision',
          'expectedPlayerRevision',
          'targetId',
          'expectedProvider',
          'expectedTargetKind',
          'expectedQueueId',
          'expectedGroupMembers',
          'expiresAt',
          'proposalLimitPerUser',
          'skipQuorumPercent',
        });
        _id(body['installationId']);
        _revision(body['expectedInstallationRevision']);
        _revision(body['expectedCoreRevision']);
        _revision(body['expectedManagerRevision']);
        _revision(body['expectedPlayerRevision']);
        final expiresAt = body['expiresAt'];
        final members = body['expectedGroupMembers'];
        final proposalLimit = body['proposalLimitPerUser'];
        final quorum = body['skipQuorumPercent'];
        if (body['targetId'] is! String ||
            body['expectedProvider'] is! String ||
            body['expectedTargetKind'] is! String ||
            body['expectedQueueId'] != null &&
                body['expectedQueueId'] is! String ||
            members is! List ||
            !members.every((item) => item is String) ||
            expiresAt is! int ||
            expiresAt < 1 ||
            expiresAt > 253402300799 ||
            proposalLimit is! int ||
            proposalLimit < 1 ||
            proposalLimit > 3 ||
            quorum is! int ||
            quorum < 50 ||
            quorum > 100) {
          _invalid();
        }
        return ServerPartyDjPendingEffect._(
          kind: ServerPartyDjEffectKind.create,
          roomId: null,
          proposalId: null,
          requestId: requestId,
          body: Map.unmodifiable(body),
        );
      case 'join':
        if (roomId == null || value['proposalId'] != null) _invalid();
        final body = _object(bodyRaw, {
          'schemaVersion',
          'requestId',
          'inviteCode',
          'expectedRoomRevision',
        });
        _id(body['inviteCode']);
        _revision(body['expectedRoomRevision']);
        return ServerPartyDjPendingEffect._(
          kind: ServerPartyDjEffectKind.join,
          roomId: roomId,
          proposalId: null,
          requestId: requestId,
          body: Map.unmodifiable(body),
        );
      case 'proposal':
        if (roomId == null || value['proposalId'] != null) _invalid();
        final body = _object(bodyRaw, {
          'schemaVersion',
          'requestId',
          'catalogRequestId',
          'expectedRoomRevision',
          'catalogQuery',
          'mediaUri',
          'name',
          'providerSetupId',
          'expectedProviderRevision',
          'providerDomain',
          'providerInstanceId',
        });
        _id(body['catalogRequestId']);
        _revision(body['expectedRoomRevision']);
        _id(body['providerSetupId']);
        _revision(body['expectedProviderRevision']);
        if (body['catalogQuery'] is! String ||
            body['name'] is! String ||
            body['mediaUri'] is! String ||
            body['providerInstanceId'] is! String ||
            !const {
              'spotify',
              'apple_music',
              'ytmusic',
            }.contains(body['providerDomain'])) {
          _invalid();
        }
        return ServerPartyDjPendingEffect._(
          kind: ServerPartyDjEffectKind.proposal,
          roomId: roomId,
          proposalId: null,
          requestId: requestId,
          body: Map.unmodifiable(body),
        );
      case 'decision':
        if (roomId == null) _invalid();
        final body = _object(bodyRaw, {
          'schemaVersion',
          'requestId',
          'expectedRoomRevision',
          'expectedProposalRevision',
          'decision',
          'expectedPlayerRevision',
        });
        final decision = body['decision'];
        final playerRevision = body['expectedPlayerRevision'];
        if ((decision != 'approve' && decision != 'reject') ||
            decision == 'approve' && playerRevision == null ||
            decision == 'reject' && playerRevision != null) {
          _invalid();
        }
        _revision(body['expectedRoomRevision']);
        _revision(body['expectedProposalRevision']);
        if (playerRevision != null) _revision(playerRevision);
        return ServerPartyDjPendingEffect._(
          kind: ServerPartyDjEffectKind.decision,
          roomId: roomId,
          proposalId: _id(value['proposalId']),
          requestId: requestId,
          body: Map.unmodifiable(body),
        );
      case 'skip':
        if (roomId == null || value['proposalId'] != null) _invalid();
        final body = _object(bodyRaw, {
          'schemaVersion',
          'requestId',
          'expectedRoomRevision',
          'expectedParticipantRevision',
          'expectedPlayerRevision',
        });
        _revision(body['expectedRoomRevision']);
        _revision(body['expectedParticipantRevision']);
        _revision(body['expectedPlayerRevision']);
        return ServerPartyDjPendingEffect._(
          kind: ServerPartyDjEffectKind.skip,
          roomId: roomId,
          proposalId: null,
          requestId: requestId,
          body: Map.unmodifiable(body),
        );
      default:
        _invalid();
    }
  }

  final ServerPartyDjEffectKind kind;
  final String requestId;
  final String? roomId;
  final String? proposalId;
  final Map<String, Object?> body;

  Map<String, Object?> toJson() => {
    'kind': kind.name,
    'roomId': roomId,
    'proposalId': proposalId,
    'requestId': requestId,
    'body': body,
  };
}

final class ServerPartyDjRecoveryState {
  const ServerPartyDjRecoveryState({
    required this.roomId,
    required this.invitation,
    required this.expiresAt,
    required this.pendingEffect,
  });

  factory ServerPartyDjRecoveryState.fromJson(Object? raw) {
    final value = _object(raw, {
      'roomId',
      'invitation',
      'expiresAt',
      'pendingEffect',
    });
    final expiresAt = value['expiresAt'];
    if (expiresAt is! int || expiresAt < 1 || expiresAt > 253402300799) {
      _invalid();
    }
    final invitationRaw = value['invitation'];
    final invitation = invitationRaw == null
        ? null
        : ServerPartyDjInvitation.parse(invitationRaw as String);
    final roomIdRaw = value['roomId'];
    final roomId = roomIdRaw == null ? null : _id(roomIdRaw);
    if (invitation != null && invitation.roomId != roomId) _invalid();
    final pendingRaw = value['pendingEffect'];
    final pending = pendingRaw == null
        ? null
        : ServerPartyDjPendingEffect.fromJson(pendingRaw);
    if (roomId == null && pending?.kind != ServerPartyDjEffectKind.create ||
        roomId != null && pending?.kind == ServerPartyDjEffectKind.create ||
        roomId != null &&
            pending?.roomId != null &&
            pending?.roomId != roomId) {
      _invalid();
    }
    return ServerPartyDjRecoveryState(
      roomId: roomId,
      invitation: invitation,
      expiresAt: DateTime.fromMillisecondsSinceEpoch(
        expiresAt * 1000,
        isUtc: true,
      ),
      pendingEffect: pending,
    );
  }

  final String? roomId;
  final ServerPartyDjInvitation? invitation;
  final DateTime expiresAt;
  final ServerPartyDjPendingEffect? pendingEffect;

  ServerPartyDjRecoveryState copyWith({
    ServerPartyDjInvitation? invitation,
    bool clearInvitation = false,
    ServerPartyDjPendingEffect? pendingEffect,
    bool clearPendingEffect = false,
    required int roomRevision,
    DateTime? expiresAt,
  }) {
    final selectedRoomId = roomId;
    if (selectedRoomId == null) _invalid();
    return ServerPartyDjRecoveryState(
      roomId: selectedRoomId,
      invitation: clearInvitation
          ? null
          : invitation == null
          ? this.invitation == null
                ? null
                : ServerPartyDjInvitation(
                    roomId: selectedRoomId,
                    roomRevision: roomRevision,
                    inviteCode: this.invitation!.inviteCode,
                  )
          : ServerPartyDjInvitation(
              roomId: selectedRoomId,
              roomRevision: roomRevision,
              inviteCode: invitation.inviteCode,
            ),
      expiresAt: expiresAt ?? this.expiresAt,
      pendingEffect: clearPendingEffect
          ? null
          : pendingEffect ?? this.pendingEffect,
    );
  }

  Map<String, Object?> toJson() => {
    'roomId': roomId,
    'invitation': invitation?.value,
    'expiresAt': expiresAt.toUtc().millisecondsSinceEpoch ~/ 1000,
    'pendingEffect': pendingEffect?.toJson(),
  };
}

abstract interface class ServerPartyDjRecoveryBackend {
  Future<String?> read(String key);
  Future<void> write(String key, String? value);
  Future<bool> writeGuarded(
    String key,
    String value, {
    required bool Function() current,
  });
}

final class SecureServerPartyDjRecoveryBackend
    implements ServerPartyDjRecoveryBackend {
  SecureServerPartyDjRecoveryBackend([FlutterSecureStorage? storage])
    : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) =>
      ConfigurationWrites.run(() => _storage.read(key: key));

  @override
  Future<void> write(String key, String? value) => ConfigurationWrites.run(
    () => value == null
        ? _storage.delete(key: key)
        : _storage.write(key: key, value: value),
  );

  @override
  Future<bool> writeGuarded(
    String key,
    String value, {
    required bool Function() current,
  }) => ConfigurationWrites.run(() async {
    bool isCurrent() {
      try {
        return current();
      } catch (_) {
        return false;
      }
    }

    if (!isCurrent()) return false;
    await _storage.write(key: key, value: value);
    if (isCurrent()) return true;
    if (await _storage.read(key: key) == value) {
      await _storage.delete(key: key);
    }
    return false;
  });
}

final class ServerPartyDjRecoveryStore {
  ServerPartyDjRecoveryStore({
    ServerPartyDjRecoveryBackend? backend,
    DateTime Function()? now,
  }) : _backend = backend ?? SecureServerPartyDjRecoveryBackend(),
       _now = now ?? DateTime.now;

  static const _maximumBytes = 8192;
  final ServerPartyDjRecoveryBackend _backend;
  final DateTime Function() _now;

  Future<ServerPartyDjRecoveryState?> read(
    ServerPartyDjRecoveryScope scope, {
    required bool Function() current,
  }) async {
    if (!current()) return null;
    final String? raw;
    try {
      raw = await _backend.read(scope.storageKey);
    } catch (_) {
      throw const LarenorServerException('storage_failed');
    }
    if (!current() || raw == null) return null;
    var remove = false;
    try {
      if (raw.length > _maximumBytes ||
          utf8.encode(raw).length > _maximumBytes) {
        remove = true;
      } else {
        final record = _object(jsonDecode(raw), {
          'schemaVersion',
          'scope',
          'state',
        });
        if (record['schemaVersion'] != 1 || !scope.matches(record['scope'])) {
          _invalid();
        }
        final state = ServerPartyDjRecoveryState.fromJson(record['state']);
        if (_now().toUtc().isBefore(state.expiresAt)) return state;
        remove = true;
      }
    } catch (_) {
      remove = true;
    }
    if (!remove || !current()) return null;
    try {
      await _backend.write(scope.storageKey, null);
    } catch (_) {
      throw const LarenorServerException('storage_failed');
    }
    return null;
  }

  Future<void> write(
    ServerPartyDjRecoveryScope scope,
    ServerPartyDjRecoveryState state, {
    required bool Function() current,
  }) async {
    if (!current()) throw const LarenorServerException('retired');
    final raw = jsonEncode({
      'schemaVersion': 1,
      'scope': scope.toJson(),
      'state': state.toJson(),
    });
    if (utf8.encode(raw).length > _maximumBytes) {
      throw const LarenorServerException('storage_failed');
    }
    try {
      if (!await _backend.writeGuarded(
        scope.storageKey,
        raw,
        current: current,
      )) {
        throw const LarenorServerException('retired');
      }
    } on LarenorServerException {
      rethrow;
    } catch (_) {
      throw const LarenorServerException('storage_failed');
    }
    if (!current()) throw const LarenorServerException('retired');
  }

  Future<void> clear(ServerPartyDjRecoveryScope scope) async {
    try {
      await _backend.write(scope.storageKey, null);
    } catch (_) {
      throw const LarenorServerException('storage_failed');
    }
  }
}
