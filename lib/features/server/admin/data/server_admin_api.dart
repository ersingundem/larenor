import '../../data/larenor_server_api.dart';
import '../../domain/server_models.dart';
import '../domain/server_admin_models.dart';

class ServerAdminApi {
  const ServerAdminApi(this.api, this.token);
  final LarenorServerApi api;
  final String token;

  Future<List<AdminUser>> users() async {
    final json = await api.request('GET', '/admin/users', token: token);
    return _list(json?['users'], 256, AdminUser.fromJson, (item) => item.id);
  }

  Future<AdminUser> create({
    required String username,
    required ServerRole role,
    required String password,
  }) async {
    if (!validAdminUsername(username) || !validAdminPassword(password)) {
      throw const LarenorServerException('invalid_request');
    }
    return _user(
      await api.request(
        'POST',
        '/admin/users',
        token: token,
        body: {
          'username': username,
          'role': role.name,
          'initialPassword': password,
        },
      ),
    );
  }

  Future<AdminUser> update(
    AdminUser previous, {
    required ServerRole role,
    required bool disabled,
  }) async => _user(
    await api.request(
      'PATCH',
      '/admin/users/${adminId(previous.id)}',
      token: token,
      body: {
        'expectedRevision': previous.revision,
        'role': role.name,
        'disabled': disabled,
      },
    ),
  );

  Future<AdminUser> resetPassword(AdminUser previous, String password) async {
    if (!validAdminPassword(password)) {
      throw const LarenorServerException('invalid_request');
    }
    return _user(
      await api.request(
        'POST',
        '/admin/users/${adminId(previous.id)}/password',
        token: token,
        body: {
          'expectedRevision': previous.revision,
          'temporaryPassword': password,
        },
      ),
    );
  }

  Future<AdminPage<AdminDeviceSession>> sessions({String? cursor}) async {
    final json = await api.request(
      'GET',
      '/admin/sessions',
      token: token,
      queryParameters: {
        'limit': '50',
        if (cursor != null) 'cursor': adminId(cursor),
      },
    );
    final items = _list(
      json?['sessions'],
      50,
      AdminDeviceSession.fromJson,
      (item) => item.id,
    );
    final next = json?['nextCursor'] == null
        ? null
        : adminId(json!['nextCursor']);
    if (next != null &&
        (next == cursor || items.isEmpty || next != items.last.id)) {
      throw const LarenorServerException('invalid_response');
    }
    return AdminPage(items, next);
  }

  Future<void> revoke(String familyId) async {
    await api.request(
      'DELETE',
      '/admin/sessions/${adminId(familyId)}',
      token: token,
      allowEmpty: true,
    );
  }

  Future<AdminPage<AdminAuditEvent>> audit({String? cursor}) async {
    final json = await api.request(
      'GET',
      '/admin/audit',
      token: token,
      queryParameters: {
        'limit': '50',
        if (cursor != null) 'cursor': adminAuditCursor(cursor),
      },
    );
    final items = _list(
      json?['events'],
      50,
      AdminAuditEvent.fromJson,
      (item) => item.id,
    );
    final next = json?['nextCursor'] == null
        ? null
        : adminAuditCursor(json!['nextCursor']);
    BigInt? previous = cursor == null ? null : BigInt.parse(cursor);
    for (final item in items) {
      final current = BigInt.parse(item.id);
      if (previous != null && current >= previous) {
        throw const LarenorServerException('invalid_response');
      }
      previous = current;
    }
    if (next != null && (items.isEmpty || next != items.last.id)) {
      throw const LarenorServerException('invalid_response');
    }
    return AdminPage(items, next);
  }

  AdminUser _user(Map<String, dynamic>? json) =>
      AdminUser.fromJson(serverObject(json?['user']));

  List<T> _list<T>(
    Object? value,
    int max,
    T Function(Map<String, dynamic>) parse,
    String Function(T) id,
  ) {
    if (value is! List || value.length > max) {
      throw const LarenorServerException('invalid_response');
    }
    final result = value.map((item) => parse(serverObject(item))).toList();
    if (result.map(id).toSet().length != result.length) {
      throw const LarenorServerException('invalid_response');
    }
    return List.unmodifiable(result);
  }
}
