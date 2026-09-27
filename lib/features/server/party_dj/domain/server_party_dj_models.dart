import '../../domain/server_models.dart';
import '../../music_manager/domain/server_music_manager_models.dart';

Never _invalid() => throw const LarenorServerException('invalid_response');

Map<String, dynamic> _object(Object? raw, Set<String> keys) {
  final value = serverObject(raw);
  if (value.length != keys.length || !value.keys.every(keys.contains)) {
    _invalid();
  }
  return value;
}

String _id(Object? raw) {
  if (raw is! String || !RegExp(r'^[0-9a-f]{32}$').hasMatch(raw)) _invalid();
  return raw;
}

String _binding(Object? raw) {
  if (raw is! String ||
      !RegExp(r'^[A-Za-z0-9][A-Za-z0-9_.:\-]{0,127}$').hasMatch(raw)) {
    _invalid();
  }
  return raw;
}

String _providerDomain(Object? raw) {
  if (raw != 'spotify' && raw != 'apple_music' && raw != 'ytmusic') {
    _invalid();
  }
  return raw as String;
}

String _text(Object? raw, int maximum) {
  if (raw is! String ||
      raw.isEmpty ||
      raw.length > maximum ||
      raw != raw.trim() ||
      raw.contains(RegExp(r'[\x00-\x1f\x7f]'))) {
    _invalid();
  }
  return raw;
}

int _revision(Object? raw) {
  if (raw is! int || raw < 1 || raw > 0x7ffffffffffffffe) _invalid();
  return raw;
}

DateTime _instant(Object? raw) {
  if (raw is! int || raw < 0 || raw > 253402300799) _invalid();
  return DateTime.fromMillisecondsSinceEpoch(raw * 1000, isUtc: true);
}

List<String> _bindings(Object? raw, {required int maximum}) {
  if (raw is! List ||
      raw.length > maximum ||
      raw.any((item) => item is! String)) {
    _invalid();
  }
  final result = raw.map(_binding).toList(growable: false);
  if (result.toSet().length != result.length) _invalid();
  return List.unmodifiable(result);
}

final class ServerPartyDjInvitation {
  const ServerPartyDjInvitation({
    required this.roomId,
    required this.roomRevision,
    required this.inviteCode,
  });

  factory ServerPartyDjInvitation.parse(String raw) {
    final parts = raw.trim().split(':');
    final revision = parts.length == 3 ? int.tryParse(parts[1]) : null;
    if (parts.length != 3 ||
        !RegExp(r'^[0-9a-f]{32}$').hasMatch(parts[0]) ||
        revision == null ||
        revision < 1 ||
        revision > 0x7ffffffffffffffe ||
        !RegExp(r'^[0-9a-f]{32}$').hasMatch(parts[2])) {
      throw const LarenorServerException('invalid_request');
    }
    return ServerPartyDjInvitation(
      roomId: parts[0],
      roomRevision: revision,
      inviteCode: parts[2],
    );
  }

  final String roomId, inviteCode;
  final int roomRevision;
  String get value => '$roomId:$roomRevision:$inviteCode';
}

enum ServerPartyDjRoomState { active, closed }

enum ServerPartyDjProposalStatus {
  pending,
  approving,
  approved,
  rejected,
  needsAttention,
}

final class ServerPartyDjAuthority {
  const ServerPartyDjAuthority._({
    required this.installationId,
    required this.installationRevision,
    required this.coreRevision,
    required this.managerRevision,
    required this.playerRevision,
    required this.targetId,
    required this.provider,
    required this.targetKind,
    required this.queueId,
    required this.groupMembers,
  });

  factory ServerPartyDjAuthority.fromJson(
    Object? raw,
    ServerSession session,
    String roomId,
  ) {
    final context = session.context;
    if (context == null || session.sessionFamilyId == null) _invalid();
    final value = _object(raw, {
      'schemaVersion',
      'coreId',
      'homeId',
      'roomId',
      'installationId',
      'installationRevision',
      'coreRevision',
      'managerRevision',
      'playerRevision',
      'targetId',
      'provider',
      'targetKind',
      'queueId',
      'groupMembers',
    });
    if (value['schemaVersion'] != 1 ||
        value['coreId'] != context.coreId ||
        value['homeId'] != context.homeId ||
        value['roomId'] != roomId ||
        value['queueId'] != null && value['queueId'] is! String) {
      _invalid();
    }
    return ServerPartyDjAuthority._(
      installationId: _id(value['installationId']),
      installationRevision: _revision(value['installationRevision']),
      coreRevision: _revision(value['coreRevision']),
      managerRevision: _revision(value['managerRevision']),
      playerRevision: _revision(value['playerRevision']),
      targetId: _binding(value['targetId']),
      provider: _binding(value['provider']),
      targetKind: _binding(value['targetKind']),
      queueId: value['queueId'] == null ? null : _binding(value['queueId']),
      groupMembers: _bindings(value['groupMembers'], maximum: 64),
    );
  }

  final String installationId, targetId, provider, targetKind;
  final String? queueId;
  final int installationRevision, coreRevision, managerRevision, playerRevision;
  final List<String> groupMembers;

  bool matches(ServerMusicManager manager, ServerMusicReceiver receiver) =>
      manager.installationId == installationId &&
      manager.installationRevision == installationRevision &&
      manager.coreRevision == coreRevision &&
      manager.revision == managerRevision &&
      receiver.id == targetId &&
      receiver.provider == provider &&
      receiver.kind == targetKind &&
      receiver.queueId == queueId &&
      _sameStrings(receiver.groupMembers, groupMembers);
}

final class ServerPartyDjParticipant {
  const ServerPartyDjParticipant._({
    required this.accountId,
    required this.revision,
    required this.isHost,
    required this.connected,
    required this.lastSeenAt,
    required this.ownedByCurrentSession,
  });

  factory ServerPartyDjParticipant.fromJson(Object? raw) {
    final value = _object(raw, {
      'schemaVersion',
      'accountId',
      'revision',
      'isHost',
      'connected',
      'lastSeenAt',
      'ownedByCurrentSession',
    });
    if (value['schemaVersion'] != 1 ||
        value['isHost'] is! bool ||
        value['connected'] is! bool ||
        value['ownedByCurrentSession'] is! bool) {
      _invalid();
    }
    return ServerPartyDjParticipant._(
      accountId: _id(value['accountId']),
      revision: _revision(value['revision']),
      isHost: value['isHost'] as bool,
      connected: value['connected'] as bool,
      lastSeenAt: _instant(value['lastSeenAt']),
      ownedByCurrentSession: value['ownedByCurrentSession'] as bool,
    );
  }

  final String accountId;
  final int revision;
  final bool isHost, connected, ownedByCurrentSession;
  final DateTime lastSeenAt;
}

final class ServerPartyDjProposal {
  const ServerPartyDjProposal._({
    required this.id,
    required this.revision,
    required this.accountId,
    required this.mediaUri,
    required this.name,
    required this.providerSetupId,
    required this.providerRevision,
    required this.providerDomain,
    required this.providerInstanceId,
    required this.managerRevision,
    required this.status,
    required this.upVotes,
    required this.submittedByCurrentUser,
    required this.votedByCurrentUser,
    required this.createdAt,
  });

  factory ServerPartyDjProposal.fromJson(Object? raw) {
    final value = _object(raw, {
      'schemaVersion',
      'proposalId',
      'revision',
      'accountId',
      'mediaUri',
      'name',
      'providerSetupId',
      'providerRevision',
      'providerDomain',
      'providerInstanceId',
      'managerRevision',
      'status',
      'upVotes',
      'submittedByCurrentUser',
      'votedByCurrentUser',
      'createdAt',
    });
    final votes = value['upVotes'];
    if (value['schemaVersion'] != 1 ||
        votes is! int ||
        votes < 0 ||
        votes > 16 ||
        value['submittedByCurrentUser'] is! bool ||
        value['votedByCurrentUser'] is! bool) {
      _invalid();
    }
    return ServerPartyDjProposal._(
      id: _id(value['proposalId']),
      revision: _revision(value['revision']),
      accountId: _id(value['accountId']),
      mediaUri: _mediaUri(value['mediaUri']),
      name: _text(value['name'], 512),
      providerSetupId: _id(value['providerSetupId']),
      providerRevision: _revision(value['providerRevision']),
      providerDomain: _providerDomain(value['providerDomain']),
      providerInstanceId: _binding(value['providerInstanceId']),
      managerRevision: _revision(value['managerRevision']),
      status: switch (value['status']) {
        'pending' => ServerPartyDjProposalStatus.pending,
        'approving' => ServerPartyDjProposalStatus.approving,
        'approved' => ServerPartyDjProposalStatus.approved,
        'rejected' => ServerPartyDjProposalStatus.rejected,
        'needs_attention' => ServerPartyDjProposalStatus.needsAttention,
        _ => _invalid(),
      },
      upVotes: votes,
      submittedByCurrentUser: value['submittedByCurrentUser'] as bool,
      votedByCurrentUser: value['votedByCurrentUser'] as bool,
      createdAt: _instant(value['createdAt']),
    );
  }

  final String id,
      accountId,
      mediaUri,
      name,
      providerSetupId,
      providerDomain,
      providerInstanceId;
  final int revision, providerRevision, managerRevision, upVotes;
  final ServerPartyDjProposalStatus status;
  final bool submittedByCurrentUser, votedByCurrentUser;
  final DateTime createdAt;
  bool get pending => status == ServerPartyDjProposalStatus.pending;
}

final class ServerPartyDjRoom {
  const ServerPartyDjRoom._({
    required this.id,
    required this.authority,
    required this.revision,
    required this.state,
    required this.hostAccountId,
    required this.expiresAt,
    required this.proposalLimitPerUser,
    required this.skipQuorumPercent,
    required this.skipVotes,
    required this.skipVotesRequired,
    required this.skipNeedsAttention,
    required this.participants,
    required this.proposals,
    required this.currentParticipantRevision,
  });

  factory ServerPartyDjRoom.fromJson(Object? raw, ServerSession session) {
    final value = _object(raw, {
      'schemaVersion',
      'authority',
      'revision',
      'state',
      'hostAccountId',
      'expiresAt',
      'proposalLimitPerUser',
      'skipQuorumPercent',
      'skipVotes',
      'skipVotesRequired',
      'skipNeedsAttention',
      'participants',
      'proposals',
      'currentParticipantRevision',
    });
    final authorityRaw = serverObject(value['authority']);
    final roomId = _id(authorityRaw['roomId']);
    final participantRaw = value['participants'];
    final proposalRaw = value['proposals'];
    final proposalLimit = value['proposalLimitPerUser'];
    final skipPercent = value['skipQuorumPercent'];
    final skipVotes = value['skipVotes'];
    final skipRequired = value['skipVotesRequired'];
    if (value['schemaVersion'] != 1 ||
        participantRaw is! List ||
        participantRaw.isEmpty ||
        participantRaw.length > 16 ||
        proposalRaw is! List ||
        proposalRaw.length > 64 ||
        proposalLimit is! int ||
        proposalLimit < 1 ||
        proposalLimit > 3 ||
        skipPercent is! int ||
        skipPercent < 50 ||
        skipPercent > 100 ||
        skipVotes is! int ||
        skipVotes < 0 ||
        skipVotes > 16 ||
        skipRequired is! int ||
        skipRequired < 1 ||
        skipRequired > 16 ||
        value['skipNeedsAttention'] is! bool) {
      _invalid();
    }
    final participants = participantRaw
        .map(ServerPartyDjParticipant.fromJson)
        .toList(growable: false);
    final proposals = proposalRaw
        .map(ServerPartyDjProposal.fromJson)
        .toList(growable: false);
    final hostId = _id(value['hostAccountId']);
    final self = participants.where((item) => item.ownedByCurrentSession);
    final hosts = participants.where((item) => item.isHost);
    if (participants.map((item) => item.accountId).toSet().length !=
            participants.length ||
        proposals.map((item) => item.id).toSet().length != proposals.length ||
        self.length != 1 ||
        self.single.accountId != session.user.id ||
        self.single.revision != value['currentParticipantRevision'] ||
        hosts.length != 1 ||
        hosts.single.accountId != hostId ||
        skipVotes > participants.where((item) => item.connected).length) {
      _invalid();
    }
    return ServerPartyDjRoom._(
      id: roomId,
      authority: ServerPartyDjAuthority.fromJson(
        value['authority'],
        session,
        roomId,
      ),
      revision: _revision(value['revision']),
      state: switch (value['state']) {
        'active' => ServerPartyDjRoomState.active,
        'closed' => ServerPartyDjRoomState.closed,
        _ => _invalid(),
      },
      hostAccountId: hostId,
      expiresAt: _instant(value['expiresAt']),
      proposalLimitPerUser: proposalLimit,
      skipQuorumPercent: skipPercent,
      skipVotes: skipVotes,
      skipVotesRequired: skipRequired,
      skipNeedsAttention: value['skipNeedsAttention'] as bool,
      participants: List.unmodifiable(participants),
      proposals: List.unmodifiable(proposals),
      currentParticipantRevision: _revision(
        value['currentParticipantRevision'],
      ),
    );
  }

  final String id, hostAccountId;
  final ServerPartyDjAuthority authority;
  final int revision,
      proposalLimitPerUser,
      skipQuorumPercent,
      skipVotes,
      skipVotesRequired,
      currentParticipantRevision;
  final bool skipNeedsAttention;
  final ServerPartyDjRoomState state;
  final DateTime expiresAt;
  final List<ServerPartyDjParticipant> participants;
  final List<ServerPartyDjProposal> proposals;

  ServerPartyDjParticipant get self =>
      participants.singleWhere((item) => item.ownedByCurrentSession);
  bool get isHost => self.isHost;
  bool get skipQuorumReached => skipVotes >= skipVotesRequired;
  int get currentUserProposalCount => proposals
      .where(
        (item) =>
            item.submittedByCurrentUser &&
            (item.status == ServerPartyDjProposalStatus.pending ||
                item.status == ServerPartyDjProposalStatus.approving ||
                item.status == ServerPartyDjProposalStatus.needsAttention),
      )
      .length;
  bool get canPropose =>
      state == ServerPartyDjRoomState.active &&
      currentUserProposalCount < proposalLimitPerUser;
}

bool _sameStrings(List<String> left, List<String> right) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index++) {
    if (left[index] != right[index]) return false;
  }
  return true;
}

String _mediaUri(Object? raw) {
  if (raw is! String || raw.isEmpty || raw.length > 2048) _invalid();
  final match = RegExp(r'^([a-z][a-z0-9_]{0,63})://[^\s]+$').firstMatch(raw);
  if (match == null ||
      const {
        'content',
        'data',
        'file',
        'ftp',
        'http',
        'https',
        'javascript',
      }.contains(match.group(1)) ||
      raw.codeUnits.any((unit) => unit < 33 || unit == 127)) {
    _invalid();
  }
  final parsed = Uri.tryParse(raw);
  if (parsed == null ||
      parsed.userInfo.isNotEmpty ||
      parsed.hasQuery ||
      parsed.hasFragment) {
    _invalid();
  }
  return raw;
}
