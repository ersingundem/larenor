import '../../domain/server_models.dart';

const _maxRevision = 9223372036854775807;

String _identity(Object? value) {
  if (value is! String || !RegExp(r'^[0-9a-f]{32}$').hasMatch(value)) {
    throw const LarenorServerException('invalid_response');
  }
  return value;
}

int _revision(Object? value) {
  if (value is! int || value < 1 || value > _maxRevision) {
    throw const LarenorServerException('invalid_response');
  }
  return value;
}

String _text(Object? value, {required int max}) {
  if (value is! String ||
      value.isEmpty ||
      value.length > max ||
      value.trim() != value ||
      value.contains(RegExp(r'[\x00-\x1f\x7f]'))) {
    throw const LarenorServerException('invalid_response');
  }
  return value;
}

double _time(Object? value) {
  if (value is! num || !value.isFinite || value < 0) {
    throw const LarenorServerException('invalid_response');
  }
  return value.toDouble();
}

Map<String, dynamic> _closed(Object? value, Set<String> keys) {
  final json = serverObject(value);
  if (json.length != keys.length || !json.keys.every(keys.contains)) {
    throw const LarenorServerException('invalid_response');
  }
  return json;
}

enum TabletManagementMode {
  standard,
  deviceOwner;

  static TabletManagementMode parse(Object? value) => switch (value) {
    'standard' => standard,
    'deviceOwner' => deviceOwner,
    _ => throw const LarenorServerException('invalid_response'),
  };
}

enum TabletFleetState {
  active,
  revoked;

  static TabletFleetState parse(Object? value) => switch (value) {
    'active' => active,
    'revoked' => revoked,
    _ => throw const LarenorServerException('invalid_response'),
  };
}

enum TabletProfileState {
  current,
  updateRequired;

  static TabletProfileState parse(Object? value) => switch (value) {
    'current' => current,
    'updateRequired' => updateRequired,
    _ => throw const LarenorServerException('invalid_response'),
  };
}

enum TabletCommandKind {
  syncProfile,
  refreshDashboard,
  restartClient,
  lockKiosk;

  TabletManagementMode get requiredMode => switch (this) {
    syncProfile || refreshDashboard => TabletManagementMode.standard,
    restartClient || lockKiosk => TabletManagementMode.deviceOwner,
  };

  static TabletCommandKind parse(Object? value) => switch (value) {
    'syncProfile' => syncProfile,
    'refreshDashboard' => refreshDashboard,
    'restartClient' => restartClient,
    'lockKiosk' => lockKiosk,
    _ => throw const LarenorServerException('invalid_response'),
  };
}

enum TabletCommandState {
  pending,
  delivered,
  completed,
  expired;

  static TabletCommandState parse(Object? value) => switch (value) {
    'pending' => pending,
    'delivered' => delivered,
    'completed' => completed,
    'expired' => expired,
    _ => throw const LarenorServerException('invalid_response'),
  };
}

enum TabletCommandResult {
  succeeded,
  denied,
  failed,
  unsupported,
  expired;

  static TabletCommandResult? parse(Object? value) => switch (value) {
    null => null,
    'succeeded' => succeeded,
    'denied' => denied,
    'failed' => failed,
    'unsupported' => unsupported,
    'expired' => expired,
    _ => throw const LarenorServerException('invalid_response'),
  };
}

final class ManagedTablet {
  const ManagedTablet._({
    required this.context,
    required this.id,
    required this.revision,
    required this.name,
    required this.mode,
    required this.capabilities,
    required this.clientVersion,
    required this.desiredProfileRevision,
    required this.appliedProfileRevision,
    required this.state,
    required this.profileState,
    required this.lastSeenAt,
  });

  factory ManagedTablet.fromJson(Object? value) {
    final json = _closed(value, const {
      'schemaVersion',
      'ref',
      'revision',
      'name',
      'platform',
      'managementMode',
      'capabilities',
      'clientVersion',
      'desiredProfileRevision',
      'appliedProfileRevision',
      'state',
      'profileState',
      'lastSeenAt',
    });
    if (json['schemaVersion'] != 1 || json['platform'] != 'android') {
      throw const LarenorServerException('invalid_response');
    }
    final ref = _closed(json['ref'], const {
      'schemaVersion',
      'coreId',
      'homeId',
      'kind',
      'id',
    });
    if (ref['schemaVersion'] != 1 || ref['kind'] != 'managed_tablet') {
      throw const LarenorServerException('invalid_response');
    }
    final context = ServerContext.fromJson({
      'schemaVersion': ref['schemaVersion'],
      'coreId': ref['coreId'],
      'homeId': ref['homeId'],
    });
    final mode = TabletManagementMode.parse(json['managementMode']);
    final rawCapabilities = json['capabilities'];
    final allowed = mode == TabletManagementMode.standard
        ? const {'notifications', 'kiosk', 'media', 'screen'}
        : const {
            'notifications',
            'kiosk',
            'media',
            'screen',
            'appRestart',
            'kioskLock',
          };
    if (rawCapabilities is! List ||
        rawCapabilities.any((item) => item is! String) ||
        rawCapabilities.toSet().length != rawCapabilities.length ||
        rawCapabilities.toSet().difference(allowed).isNotEmpty ||
        !rawCapabilities.toSet().containsAll(allowed)) {
      throw const LarenorServerException('invalid_response');
    }
    final desired = _revision(json['desiredProfileRevision']);
    final applied = _revision(json['appliedProfileRevision']);
    final profile = TabletProfileState.parse(json['profileState']);
    if (applied > desired ||
        (applied == desired) != (profile == TabletProfileState.current)) {
      throw const LarenorServerException('invalid_response');
    }
    return ManagedTablet._(
      context: context,
      id: _identity(ref['id']),
      revision: _revision(json['revision']),
      name: _text(json['name'], max: 80),
      mode: mode,
      capabilities: List.unmodifiable(rawCapabilities.cast<String>()),
      clientVersion: _text(json['clientVersion'], max: 64),
      desiredProfileRevision: desired,
      appliedProfileRevision: applied,
      state: TabletFleetState.parse(json['state']),
      profileState: profile,
      lastSeenAt: _time(json['lastSeenAt']),
    );
  }

  final ServerContext context;
  final String id, name, clientVersion;
  final int revision, desiredProfileRevision, appliedProfileRevision;
  final TabletManagementMode mode;
  final List<String> capabilities;
  final TabletFleetState state;
  final TabletProfileState profileState;
  final double lastSeenAt;

  bool supports(TabletCommandKind command) =>
      command.requiredMode == TabletManagementMode.standard ||
      mode == TabletManagementMode.deviceOwner;

  bool sameAuthority(ManagedTablet other) =>
      context == other.context && id == other.id;

  @override
  String toString() =>
      'ManagedTablet(id: $id, revision: $revision, mode: ${mode.name}, state: ${state.name})';
}

final class ManagedTabletList {
  const ManagedTabletList(this.context, this.tablets);
  factory ManagedTabletList.fromJson(Object? value) {
    final json = _closed(value, const {'schemaVersion', 'scope', 'tablets'});
    if (json['schemaVersion'] != 1) {
      throw const LarenorServerException('invalid_response');
    }
    final context = ServerContext.fromJson(json['scope']);
    final raw = json['tablets'];
    if (raw is! List || raw.length > 256) {
      throw const LarenorServerException('invalid_response');
    }
    final tablets = raw.map(ManagedTablet.fromJson).toList();
    if (tablets.any((item) => item.context != context) ||
        tablets.map((item) => item.id).toSet().length != tablets.length) {
      throw const LarenorServerException('invalid_response');
    }
    return ManagedTabletList(context, List.unmodifiable(tablets));
  }
  final ServerContext context;
  final List<ManagedTablet> tablets;
}

final class ManagedTabletCommand {
  const ManagedTabletCommand._({
    required this.id,
    required this.sequence,
    required this.kind,
    required this.requiredMode,
    required this.policyRevision,
    required this.expiresAt,
    required this.state,
    required this.result,
    required this.createdAt,
    required this.completedAt,
  });
  factory ManagedTabletCommand.fromJson(Object? value) {
    final json = _closed(value, const {
      'schemaVersion',
      'id',
      'sequence',
      'command',
      'requiredMode',
      'policyRevision',
      'expiresAt',
      'state',
      'result',
      'createdAt',
      'completedAt',
    });
    if (json['schemaVersion'] != 1) {
      throw const LarenorServerException('invalid_response');
    }
    final kind = TabletCommandKind.parse(json['command']);
    final requiredMode = TabletManagementMode.parse(json['requiredMode']);
    final state = TabletCommandState.parse(json['state']);
    final result = TabletCommandResult.parse(json['result']);
    final completedAt = json['completedAt'] == null
        ? null
        : _time(json['completedAt']);
    final expiresAt = _time(json['expiresAt']);
    final createdAt = _time(json['createdAt']);
    final terminal =
        state == TabletCommandState.completed ||
        state == TabletCommandState.expired;
    if (requiredMode != kind.requiredMode ||
        createdAt >= expiresAt ||
        (terminal
            ? result == null || completedAt == null
            : result != null || completedAt != null) ||
        (completedAt != null && completedAt < createdAt) ||
        (state == TabletCommandState.completed && completedAt! >= expiresAt) ||
        (state == TabletCommandState.expired && completedAt! < expiresAt) ||
        (state == TabletCommandState.expired) !=
            (result == TabletCommandResult.expired) ||
        (state == TabletCommandState.completed &&
            result == TabletCommandResult.expired)) {
      throw const LarenorServerException('invalid_response');
    }
    return ManagedTabletCommand._(
      id: _identity(json['id']),
      sequence: _revision(json['sequence']),
      kind: kind,
      requiredMode: requiredMode,
      policyRevision: _revision(json['policyRevision']),
      expiresAt: expiresAt,
      state: state,
      result: result,
      createdAt: createdAt,
      completedAt: completedAt,
    );
  }
  final String id;
  final int sequence;
  final TabletCommandKind kind;
  final TabletManagementMode requiredMode;
  final int policyRevision;
  final double expiresAt;
  final TabletCommandState state;
  final TabletCommandResult? result;
  final double createdAt;
  final double? completedAt;

  bool sameReceipt(ManagedTabletCommand other) =>
      id == other.id &&
      sequence == other.sequence &&
      kind == other.kind &&
      requiredMode == other.requiredMode &&
      policyRevision == other.policyRevision &&
      expiresAt == other.expiresAt &&
      state == other.state &&
      result == other.result &&
      createdAt == other.createdAt &&
      completedAt == other.completedAt;

  @override
  String toString() =>
      'ManagedTabletCommand(id: $id, sequence: $sequence, state: ${state.name})';
}

final class ManagedTabletCommandPage {
  const ManagedTabletCommandPage({
    required this.tabletRevision,
    required this.commands,
    required this.nextAfter,
  });
  factory ManagedTabletCommandPage.fromJson(Object? value) {
    final json = _closed(value, const {
      'schemaVersion',
      'tabletRevision',
      'commands',
      'nextAfter',
    });
    if (json['schemaVersion'] != 1) {
      throw const LarenorServerException('invalid_response');
    }
    final raw = json['commands'];
    if (raw is! List || raw.length > 50) {
      throw const LarenorServerException('invalid_response');
    }
    final commands = raw.map(ManagedTabletCommand.fromJson).toList();
    final sequences = commands.map((item) => item.sequence).toList();
    if (sequences.toSet().length != sequences.length ||
        commands.map((item) => item.id).toSet().length != commands.length) {
      throw const LarenorServerException('invalid_response');
    }
    for (var index = 1; index < sequences.length; index++) {
      if (sequences[index] <= sequences[index - 1]) {
        throw const LarenorServerException('invalid_response');
      }
    }
    final next = json['nextAfter'] == null
        ? null
        : _revision(json['nextAfter']);
    if (next != null && (commands.isEmpty || next != commands.last.sequence)) {
      throw const LarenorServerException('invalid_response');
    }
    return ManagedTabletCommandPage(
      tabletRevision: _revision(json['tabletRevision']),
      commands: List.unmodifiable(commands),
      nextAfter: next,
    );
  }
  final int tabletRevision;
  final List<ManagedTabletCommand> commands;
  final int? nextAfter;
}
