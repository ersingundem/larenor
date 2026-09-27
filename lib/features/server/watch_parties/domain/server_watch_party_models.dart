import '../../domain/server_models.dart';

Never _invalid() => throw const LarenorServerException('invalid_response');

Map<String, dynamic> _object(Object? raw, Set<String> keys) {
  final value = serverObject(raw);
  if (value.length != keys.length || !value.keys.every(keys.contains)) {
    _invalid();
  }
  return value;
}

String _identity(Object? raw) {
  if (raw is! String || !RegExp(r'^[0-9a-f]{32}$').hasMatch(raw)) _invalid();
  return raw;
}

int _revision(Object? raw) {
  if (raw is! int || raw < 1 || raw > 0x7ffffffffffffffe) _invalid();
  return raw;
}

final class ServerWatchPartyInvitation {
  const ServerWatchPartyInvitation({
    required this.roomId,
    required this.roomRevision,
    required this.itemId,
    required this.inviteCode,
  });

  factory ServerWatchPartyInvitation.parse(String raw) {
    final parts = raw.trim().split(':');
    final revision = parts.length == 4 ? int.tryParse(parts[1]) : null;
    if (parts.length != 4 ||
        !RegExp(r'^[0-9a-f]{32}$').hasMatch(parts[0]) ||
        revision == null ||
        revision < 1 ||
        !RegExp(r'^[0-9a-f]{32}$').hasMatch(parts[2]) ||
        !RegExp(r'^[0-9a-f]{32}$').hasMatch(parts[3])) {
      throw const LarenorServerException('invalid_request');
    }
    return ServerWatchPartyInvitation(
      roomId: parts[0],
      roomRevision: revision,
      itemId: parts[2],
      inviteCode: parts[3],
    );
  }

  final String roomId, itemId, inviteCode;
  final int roomRevision;

  String get value => '$roomId:$roomRevision:$itemId:$inviteCode';
}

enum ServerWatchPartyPlaybackState { playing, paused, buffering }

enum ServerWatchPartyDirectiveAction {
  none,
  play,
  pause,
  seekAndPlay,
  unsupported,
}

final class ServerWatchPartyTarget {
  const ServerWatchPartyTarget({
    required this.targetId,
    required this.targetRevision,
    required this.canSeek,
    required this.canPause,
  });

  factory ServerWatchPartyTarget.fromJson(Object? raw) {
    final value = _object(raw, {
      'schemaVersion',
      'targetId',
      'targetRevision',
      'canSeek',
      'canPause',
    });
    final target = value['targetId'];
    if (value['schemaVersion'] != 1 ||
        target is! String ||
        !RegExp(r'^[A-Za-z0-9][A-Za-z0-9_.:\-]{0,127}$').hasMatch(target) ||
        value['canSeek'] is! bool ||
        value['canPause'] is! bool) {
      _invalid();
    }
    return ServerWatchPartyTarget(
      targetId: target,
      targetRevision: _revision(value['targetRevision']),
      canSeek: value['canSeek'] as bool,
      canPause: value['canPause'] as bool,
    );
  }

  final String targetId;
  final int targetRevision;
  final bool canSeek, canPause;

  Map<String, Object?> toJson() => {
    'schemaVersion': 1,
    'targetId': targetId,
    'targetRevision': targetRevision,
    'canSeek': canSeek,
    'canPause': canPause,
  };
}

final class ServerWatchPartyPlayback {
  const ServerWatchPartyPlayback({
    required this.state,
    required this.positionMs,
    required this.measuredRoundTripMs,
  });

  factory ServerWatchPartyPlayback.fromJson(Object? raw) {
    final value = _object(raw, {
      'schemaVersion',
      'state',
      'positionMs',
      'measuredRoundTripMs',
    });
    final position = value['positionMs'];
    final roundTrip = value['measuredRoundTripMs'];
    if (value['schemaVersion'] != 1 ||
        position is! int ||
        position < 0 ||
        position > 8640000000 ||
        roundTrip is! int ||
        roundTrip < 0 ||
        roundTrip > 10000) {
      _invalid();
    }
    return ServerWatchPartyPlayback(
      state: switch (value['state']) {
        'playing' => ServerWatchPartyPlaybackState.playing,
        'paused' => ServerWatchPartyPlaybackState.paused,
        'buffering' => ServerWatchPartyPlaybackState.buffering,
        _ => _invalid(),
      },
      positionMs: position,
      measuredRoundTripMs: roundTrip,
    );
  }

  final ServerWatchPartyPlaybackState state;
  final int positionMs, measuredRoundTripMs;

  Map<String, Object?> toJson() => {
    'schemaVersion': 1,
    'state': state.name,
    'positionMs': positionMs,
    'measuredRoundTripMs': measuredRoundTripMs,
  };
}

final class ServerWatchPartyMember {
  const ServerWatchPartyMember({
    required this.accountId,
    required this.revision,
    required this.isLeader,
    required this.connected,
    required this.target,
    required this.playback,
  });

  factory ServerWatchPartyMember.fromJson(Object? raw) {
    final value = _object(raw, {
      'schemaVersion',
      'accountId',
      'revision',
      'isLeader',
      'connected',
      'target',
      'playback',
      'lastSeenAt',
    });
    if (value['schemaVersion'] != 1 ||
        value['isLeader'] is! bool ||
        value['connected'] is! bool ||
        value['lastSeenAt'] is! int) {
      _invalid();
    }
    return ServerWatchPartyMember(
      accountId: _identity(value['accountId']),
      revision: _revision(value['revision']),
      isLeader: value['isLeader'] as bool,
      connected: value['connected'] as bool,
      target: value['target'] == null
          ? null
          : ServerWatchPartyTarget.fromJson(value['target']),
      playback: value['playback'] == null
          ? null
          : ServerWatchPartyPlayback.fromJson(value['playback']),
    );
  }

  final String accountId;
  final int revision;
  final bool isLeader, connected;
  final ServerWatchPartyTarget? target;
  final ServerWatchPartyPlayback? playback;
}

final class ServerWatchPartyDirective {
  const ServerWatchPartyDirective({
    required this.commandRevision,
    required this.action,
    required this.positionMs,
    required this.skewMs,
    required this.toleranceMs,
  });

  factory ServerWatchPartyDirective.fromJson(Object? raw) {
    final value = _object(raw, {
      'schemaVersion',
      'commandRevision',
      'action',
      'positionMs',
      'skewMs',
      'toleranceMs',
    });
    final position = value['positionMs'];
    final skew = value['skewMs'];
    final tolerance = value['toleranceMs'];
    if (value['schemaVersion'] != 1 ||
        position is! int ||
        position < 0 ||
        position > 8640000000 ||
        skew is! int ||
        skew.abs() > 8640000000 ||
        tolerance is! int ||
        tolerance < 250 ||
        tolerance > 5000) {
      _invalid();
    }
    return ServerWatchPartyDirective(
      commandRevision: _revision(value['commandRevision']),
      action: switch (value['action']) {
        'none' => ServerWatchPartyDirectiveAction.none,
        'play' => ServerWatchPartyDirectiveAction.play,
        'pause' => ServerWatchPartyDirectiveAction.pause,
        'seek_and_play' => ServerWatchPartyDirectiveAction.seekAndPlay,
        'unsupported' => ServerWatchPartyDirectiveAction.unsupported,
        _ => _invalid(),
      },
      positionMs: position,
      skewMs: skew,
      toleranceMs: tolerance,
    );
  }

  final int commandRevision, positionMs, skewMs, toleranceMs;
  final ServerWatchPartyDirectiveAction action;
}

final class ServerWatchPartySnapshot {
  const ServerWatchPartySnapshot({
    required this.roomId,
    required this.itemId,
    required this.revision,
    required this.leaderAccountId,
    required this.expiresAt,
    required this.toleranceMs,
    required this.commandRevision,
    required this.commandAction,
    required this.commandPositionMs,
    required this.participants,
    required this.directive,
  });

  factory ServerWatchPartySnapshot.fromJson(
    Object? raw, {
    required ServerSession session,
  }) {
    final value = _object(raw, {
      'schemaVersion',
      'authority',
      'revision',
      'state',
      'leaderAccountId',
      'expiresAt',
      'toleranceMs',
      'command',
      'participants',
      'directive',
    });
    final authority = _object(value['authority'], {
      'schemaVersion',
      'coreId',
      'homeId',
      'roomId',
      'installationId',
      'installationRevision',
      'snapshotRevision',
      'jellyfinServiceRevision',
      'itemId',
      'mediaKey',
    });
    final context = session.context;
    if (value['schemaVersion'] != 1 ||
        value['state'] != 'active' ||
        context == null ||
        authority['schemaVersion'] != 1 ||
        authority['coreId'] != context.coreId ||
        authority['homeId'] != context.homeId) {
      _invalid();
    }
    final command = _object(value['command'], {
      'schemaVersion',
      'revision',
      'action',
      'positionMs',
      'issuedAtMs',
    });
    final rawMembers = value['participants'];
    final expiresAt = value['expiresAt'];
    final toleranceMs = value['toleranceMs'];
    final commandPosition = command['positionMs'];
    final commandIssued = command['issuedAtMs'];
    if (command['schemaVersion'] != 1 ||
        command['action'] != 'play' && command['action'] != 'pause' ||
        commandPosition is! int ||
        commandPosition < 0 ||
        commandPosition > 8640000000 ||
        commandIssued is! int ||
        commandIssued < 0 ||
        commandIssued > 253402300799000 ||
        rawMembers is! List ||
        rawMembers.isEmpty ||
        rawMembers.length > 16 ||
        expiresAt is! int ||
        expiresAt < 1 ||
        toleranceMs is! int ||
        toleranceMs < 250 ||
        toleranceMs > 5000 ||
        authority['mediaKey'] is! String ||
        (authority['mediaKey'] as String).isEmpty ||
        (authority['mediaKey'] as String).length > 96) {
      _invalid();
    }
    _identity(authority['installationId']);
    _revision(authority['installationRevision']);
    _revision(authority['snapshotRevision']);
    _revision(authority['jellyfinServiceRevision']);
    final itemId = _identity(authority['itemId']);
    final members = rawMembers
        .map(ServerWatchPartyMember.fromJson)
        .toList(growable: false);
    final leader = _identity(value['leaderAccountId']);
    if (members.where((member) => member.isLeader).length != 1 ||
        !members.any(
          (member) => member.isLeader && member.accountId == leader,
        ) ||
        !members.any((member) => member.accountId == session.user.id) ||
        members.map((member) => member.accountId).toSet().length !=
            members.length) {
      _invalid();
    }
    return ServerWatchPartySnapshot(
      roomId: _identity(authority['roomId']),
      itemId: itemId,
      revision: _revision(value['revision']),
      leaderAccountId: leader,
      expiresAt: expiresAt,
      toleranceMs: toleranceMs,
      commandRevision: _revision(command['revision']),
      commandAction: command['action'] as String,
      commandPositionMs: commandPosition,
      participants: List.unmodifiable(members),
      directive: value['directive'] == null
          ? null
          : ServerWatchPartyDirective.fromJson(value['directive']),
    );
  }

  final String roomId, itemId, leaderAccountId, commandAction;
  final int revision, expiresAt, toleranceMs, commandRevision;
  final int commandPositionMs;
  final List<ServerWatchPartyMember> participants;
  final ServerWatchPartyDirective? directive;

  ServerWatchPartyMember self(String accountId) =>
      participants.singleWhere((member) => member.accountId == accountId);
}
