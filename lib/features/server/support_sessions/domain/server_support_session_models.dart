import '../../domain/server_models.dart';

Never _invalid() => throw const LarenorServerException('invalid_response');

Map<Object?, Object?> _object(Object? raw, Set<String> keys) {
  if (raw is! Map ||
      raw.length != keys.length ||
      !keys.every(raw.containsKey)) {
    _invalid();
  }
  return raw;
}

String _id(Object? value) {
  if (value is! String || !RegExp(r'^[0-9a-f]{32}$').hasMatch(value)) {
    _invalid();
  }
  return value;
}

int _revision(Object? value) {
  if (value is! int || value < 1 || value > 9223372036854775807) {
    _invalid();
  }
  return value;
}

const supportCoreHealth = 'core:health.read';
const supportAuditVerify = 'core:audit.verify';
const supportResourceCount = 'home_registry:resource_count.read';
const supportEgressSummary = 'component_egress:summary.read';
const supportActivityRead = 'session:activity.read';
const serverSupportPermissions = {
  supportCoreHealth,
  supportAuditVerify,
  supportResourceCount,
  supportEgressSummary,
  supportActivityRead,
};

final class ServerSupportLogPolicy {
  const ServerSupportLogPolicy._(this.redactedFields);

  factory ServerSupportLogPolicy.fromJson(Object? raw) {
    final value = _object(raw, {'freeformLogsStored', 'redactedFields'});
    final fields = value['redactedFields'];
    const expected = {
      'authorization',
      'cookies',
      'credentials',
      'requestBody',
      'responseBody',
      'freeformLogs',
    };
    if (value['freeformLogsStored'] != false ||
        fields is! List ||
        fields.length != expected.length ||
        fields.toSet().difference(expected).isNotEmpty) {
      _invalid();
    }
    return ServerSupportLogPolicy._(List.unmodifiable(fields.cast<String>()));
  }

  final List<String> redactedFields;
}

final class ServerSupportSession {
  const ServerSupportSession._({
    required this.id,
    required this.revision,
    required this.supporterId,
    required this.supporterName,
    required this.permissions,
    required this.state,
    required this.expiresAt,
    required this.remainingSeconds,
    required this.logPolicy,
  });

  factory ServerSupportSession.fromJson(Object? raw) {
    final value = _object(raw, {
      'schemaVersion',
      'id',
      'revision',
      'supporterId',
      'supporterName',
      'permissions',
      'state',
      'expiresAt',
      'remainingSeconds',
      'createdAt',
      'updatedAt',
      'logPolicy',
    });
    final supporterId = value['supporterId'];
    final supporterName = value['supporterName'];
    final rawPermissions = value['permissions'];
    final state = value['state'];
    final expiresAt = value['expiresAt'];
    final remaining = value['remainingSeconds'];
    if (value['schemaVersion'] != 1 ||
        supporterId is! String ||
        !RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]{2,95}$').hasMatch(supporterId) ||
        supporterName is! String ||
        supporterName.isEmpty ||
        supporterName.runes.length > 80 ||
        rawPermissions is! List ||
        rawPermissions.isEmpty ||
        rawPermissions.length > 5 ||
        rawPermissions.any(
          (permission) => !serverSupportPermissions.contains(permission),
        ) ||
        rawPermissions.toSet().length != rawPermissions.length ||
        state != 'active' && state != 'revoked' && state != 'expired' ||
        expiresAt is! num ||
        !expiresAt.isFinite ||
        remaining is! int ||
        remaining < 0 ||
        remaining > 1200 ||
        value['createdAt'] is! num ||
        value['updatedAt'] is! num) {
      _invalid();
    }
    final permissions = List<String>.unmodifiable(
      rawPermissions.cast<String>(),
    );
    if (permissions.join('\n') != ([...permissions]..sort()).join('\n')) {
      _invalid();
    }
    return ServerSupportSession._(
      id: _id(value['id']),
      revision: _revision(value['revision']),
      supporterId: supporterId,
      supporterName: supporterName,
      permissions: permissions,
      state: state as String,
      expiresAt: DateTime.fromMillisecondsSinceEpoch(
        (expiresAt * 1000).round(),
        isUtc: true,
      ),
      remainingSeconds: remaining,
      logPolicy: ServerSupportLogPolicy.fromJson(value['logPolicy']),
    );
  }

  final String id, supporterId, supporterName, state;
  final int revision, remainingSeconds;
  final List<String> permissions;
  final DateTime expiresAt;
  final ServerSupportLogPolicy logPolicy;

  bool get active => state == 'active' && remainingSeconds > 0;
}

final class ServerSupportSessionList {
  const ServerSupportSessionList._(this.sessions);

  factory ServerSupportSessionList.fromJson(Object? raw) {
    final value = _object(raw, {
      'schemaVersion',
      'sessions',
      'maximumSessions',
      'maximumLifetimeSeconds',
    });
    final sessions = value['sessions'];
    if (value['schemaVersion'] != 1 ||
        value['maximumSessions'] != 64 ||
        value['maximumLifetimeSeconds'] != 1200 ||
        sessions is! List ||
        sessions.length > 64) {
      _invalid();
    }
    return ServerSupportSessionList._(
      List.unmodifiable(sessions.map(ServerSupportSession.fromJson)),
    );
  }

  final List<ServerSupportSession> sessions;
}

final class ServerSupportActivity {
  const ServerSupportActivity._(
    this.id,
    this.permission,
    this.outcome,
    this.createdAt,
  );

  factory ServerSupportActivity.fromJson(Object? raw) {
    final value = _object(raw, {
      'schemaVersion',
      'id',
      'permission',
      'outcome',
      'createdAt',
      'detailsStored',
    });
    final permission = value['permission'];
    final outcome = value['outcome'];
    final createdAt = value['createdAt'];
    if (value['schemaVersion'] != 1 ||
        permission is! String ||
        !serverSupportPermissions.contains(permission) &&
            permission != 'unrecognized' ||
        outcome != 'allowed' && outcome != 'denied' ||
        createdAt is! num ||
        !createdAt.isFinite ||
        value['detailsStored'] != false) {
      _invalid();
    }
    return ServerSupportActivity._(
      _id(value['id']),
      permission,
      outcome as String,
      DateTime.fromMillisecondsSinceEpoch(
        (createdAt * 1000).round(),
        isUtc: true,
      ),
    );
  }

  final String id, permission, outcome;
  final DateTime createdAt;
}

final class ServerSupportDetail {
  const ServerSupportDetail._(this.session, this.activity);

  factory ServerSupportDetail.fromJson(Object? raw) {
    final value = _object(raw, {'session', 'activity'});
    final activity = value['activity'];
    if (activity is! List || activity.length > 50) _invalid();
    return ServerSupportDetail._(
      ServerSupportSession.fromJson(value['session']),
      List.unmodifiable(activity.map(ServerSupportActivity.fromJson)),
    );
  }

  final ServerSupportSession session;
  final List<ServerSupportActivity> activity;
}

final class ServerSupportIssuedSession {
  const ServerSupportIssuedSession(this.session, this.accessToken);

  factory ServerSupportIssuedSession.fromJson(Object? raw) {
    final value = _object(raw, {'session', 'accessToken'});
    final token = value['accessToken'];
    if (token is! String || !RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(token)) {
      _invalid();
    }
    return ServerSupportIssuedSession(
      ServerSupportSession.fromJson(value['session']),
      token,
    );
  }

  final ServerSupportSession session;
  final String accessToken;
}
