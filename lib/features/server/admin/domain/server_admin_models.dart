import '../../domain/server_models.dart';

String adminId(Object? value) {
  if (value is! String || !RegExp(r'^[0-9a-f]{32}$').hasMatch(value)) {
    throw const LarenorServerException('invalid_response');
  }
  return value;
}

DateTime adminDate(Object? value) {
  final text = serverText(value, max: 40);
  final date = DateTime.tryParse(text);
  if (!text.endsWith('Z') || date == null || !date.isUtc) {
    throw const LarenorServerException('invalid_response');
  }
  return date;
}

int adminRevision(Object? value) {
  if (value is! int || value < 1 || value > 9007199254740991) {
    throw const LarenorServerException('invalid_response');
  }
  return value;
}

ServerRole adminRole(Object? value) => switch (value) {
  'admin' => ServerRole.admin,
  'member' => ServerRole.member,
  _ => throw const LarenorServerException('invalid_response'),
};

class AdminUser {
  const AdminUser({
    required this.id,
    required this.username,
    required this.role,
    required this.disabled,
    required this.mustChangePassword,
    required this.revision,
    required this.createdAt,
  });

  factory AdminUser.fromJson(Map<String, dynamic> json) {
    if (json['disabled'] is! bool || json['mustChangePassword'] is! bool) {
      throw const LarenorServerException('invalid_response');
    }
    final username = serverText(json['username'], max: 64);
    if (!RegExp(r'^[A-Za-z0-9_.-]+$').hasMatch(username)) {
      throw const LarenorServerException('invalid_response');
    }
    return AdminUser(
      id: adminId(json['id']),
      username: username,
      role: adminRole(json['role']),
      disabled: json['disabled'] as bool,
      mustChangePassword: json['mustChangePassword'] as bool,
      revision: adminRevision(json['revision']),
      createdAt: adminDate(json['createdAt']),
    );
  }

  final String id, username;
  final ServerRole role;
  final bool disabled, mustChangePassword;
  final int revision;
  final DateTime createdAt;
}

enum AdminSessionStatus { active, revoked, expired }

class AdminDeviceSession {
  const AdminDeviceSession({
    required this.id,
    required this.userId,
    required this.deviceName,
    required this.createdAt,
    required this.expiresAt,
    required this.revokedAt,
    required this.status,
  });

  factory AdminDeviceSession.fromJson(Map<String, dynamic> json) {
    final status = switch (json['status']) {
      'active' => AdminSessionStatus.active,
      'revoked' => AdminSessionStatus.revoked,
      'expired' => AdminSessionStatus.expired,
      _ => throw const LarenorServerException('invalid_response'),
    };
    final revoked = json['revokedAt'] == null
        ? null
        : adminDate(json['revokedAt']);
    final created = adminDate(json['createdAt']),
        expires = adminDate(json['expiresAt']);
    if ((status == AdminSessionStatus.revoked) != (revoked != null) ||
        !expires.isAfter(created)) {
      throw const LarenorServerException('invalid_response');
    }
    return AdminDeviceSession(
      id: adminId(json['id']),
      userId: adminId(json['userId']),
      deviceName: serverText(json['deviceName'], max: 100),
      createdAt: created,
      expiresAt: expires,
      revokedAt: revoked,
      status: status,
    );
  }

  final String id, userId, deviceName;
  final DateTime createdAt, expiresAt;
  final DateTime? revokedAt;
  final AdminSessionStatus status;
}

enum AdminAuditAction { create, update, resetPassword, revoke }

class AdminAuditEvent {
  const AdminAuditEvent({
    required this.id,
    required this.action,
    required this.succeeded,
    required this.timestamp,
    required this.actorId,
    required this.targetId,
  });

  factory AdminAuditEvent.fromJson(Map<String, dynamic> json) {
    final action = switch ((json['event'], json['action'], json['object'])) {
      ('admin.user.created', 'create', 'user') => AdminAuditAction.create,
      ('admin.user.updated', 'update', 'user') => AdminAuditAction.update,
      ('admin.user.password_reset', 'reset_password', 'user') =>
        AdminAuditAction.resetPassword,
      ('admin.session.revoked', 'revoke', 'session') => AdminAuditAction.revoke,
      _ => throw const LarenorServerException('invalid_response'),
    };
    if (!{'success', 'denied'}.contains(json['status'])) {
      throw const LarenorServerException('invalid_response');
    }
    return AdminAuditEvent(
      id: adminAuditCursor(json['id']),
      action: action,
      succeeded: json['status'] == 'success',
      timestamp: adminDate(json['timestamp']),
      actorId: adminId(json['actorId']),
      targetId: json['targetId'] == null ? null : adminId(json['targetId']),
    );
  }

  final String id, actorId;
  final String? targetId;
  final AdminAuditAction action;
  final bool succeeded;
  final DateTime timestamp;
}

String adminAuditCursor(Object? value) {
  if (value is! String ||
      !RegExp(r'^[1-9][0-9]{0,18}$').hasMatch(value) ||
      BigInt.parse(value) > BigInt.parse('9223372036854775807')) {
    throw const LarenorServerException('invalid_response');
  }
  return value;
}

class AdminPage<T> {
  const AdminPage(this.items, this.nextCursor);
  final List<T> items;
  final String? nextCursor;
}

bool validAdminPassword(String value) =>
    value.runes.length >= 12 &&
    value.runes.length <= 128 &&
    !RegExp(r'[\x00-\x1f\x7f]').hasMatch(value);
bool validAdminUsername(String value) =>
    value.length <= 64 && RegExp(r'^[A-Za-z0-9_.-]+$').hasMatch(value);
