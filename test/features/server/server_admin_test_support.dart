import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:larenor/features/server/data/larenor_server_api.dart';
import 'package:larenor/features/server/data/server_account_controller.dart';
import 'package:larenor/features/server/data/server_session_store.dart';
import 'package:larenor/features/server/domain/server_models.dart';

const adminId = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const memberId = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
const deviceId = 'cccccccccccccccccccccccccccccccc';
const adminPassword = 'Synthetic temporary password';

Map<String, dynamic> adminUserJson({
  String id = adminId,
  String username = 'admin',
  String role = 'admin',
  int revision = 1,
  bool disabled = false,
  bool mustChange = false,
}) => {
  'id': id,
  'username': username,
  'role': role,
  'revision': revision,
  'disabled': disabled,
  'mustChangePassword': mustChange,
  'createdAt': '2026-09-05T08:00:00Z',
};

Map<String, dynamic> adminDeviceJson({
  String id = deviceId,
  bool revoked = false,
}) => {
  'id': id,
  'userId': memberId,
  'deviceName': 'Living room tablet',
  'createdAt': '2026-09-05T08:00:00Z',
  'expiresAt': '2026-09-06T08:00:00Z',
  'revokedAt': revoked ? '2026-09-05T09:00:00Z' : null,
  'status': revoked ? 'revoked' : 'active',
};

Map<String, dynamic> adminEventJson(String id) => {
  'id': id,
  'event': 'admin.user.created',
  'action': 'create',
  'object': 'user',
  'status': 'success',
  'timestamp': '2026-09-05T08:00:00Z',
  'actorId': adminId,
  'targetId': memberId,
};

class AdminStore implements ServerSessionPersistence {
  AdminStore(this.value);
  ServerSession? value;
  @override
  Future<ServerSession?> read() async => value;
  @override
  Future<void> write(ServerSession? session) async => value = session;
}

/// All requests terminate inside MockClient; no real service is contacted.
class AdminFixture {
  AdminFixture({ServerRole role = ServerRole.admin, bool mustChange = false}) {
    user = ServerUser(
      id: adminId,
      username: 'admin',
      role: role,
      mustChangePassword: mustChange,
    );
    store = AdminStore(session());
    account = ServerAccountController(
      store: store,
      clock: () => now,
      apiFactory: (endpoint) => LarenorServerApi(
        endpoint: endpoint,
        client: MockClient(_request),
        clock: () => now,
      ),
    );
  }

  DateTime now = DateTime.utc(2026, 9, 5, 9);
  late ServerUser user;
  late AdminStore store;
  late ServerAccountController account;
  final calls = <http.Request>[];
  final users = [
    adminUserJson(),
    adminUserJson(id: memberId, username: 'member', role: 'member'),
  ];
  bool revoked = false;
  Future<http.Response> Function(http.Request)? respond;
  Completer<http.Response>? refresh;

  ServerSession session() => ServerSession(
    endpoint: ServerEndpoint('https://fixture.invalid/prefix'),
    accessToken: 'synthetic_admin_access_12345',
    refreshToken: 'synthetic_admin_refresh_12345',
    expiresAt: now.add(const Duration(hours: 1)),
    user: user,
  );

  Map<String, dynamic> userJson() => {
    'id': user.id,
    'username': user.username,
    'role': user.role.name,
    'mustChangePassword': user.mustChangePassword,
  };

  http.Response json(Object? value, [int status = 200]) => http.Response(
    jsonEncode(value),
    status,
    headers: {'content-type': 'application/json'},
  );

  http.Response pair() => json({
    'accessToken': session().accessToken,
    'refreshToken': session().refreshToken,
    'tokenType': 'Bearer',
    'expiresIn': 3600,
    'user': userJson(),
  });

  Iterable<http.Request> get adminCalls =>
      calls.where((call) => call.url.path.contains('/admin/'));
  Iterable<http.Request> get mutations =>
      adminCalls.where((call) => call.method != 'GET');

  Future<http.Response> _request(http.Request request) async {
    calls.add(request);
    if (request.url.path.endsWith('/auth/me')) {
      return json({'user': userJson()});
    }
    if (request.url.path.endsWith('/auth/refresh')) {
      return refresh?.future ?? pair();
    }
    if (request.url.path.endsWith('/auth/logout')) {
      return http.Response('', 204);
    }
    if (respond case final handler?) return handler(request);
    return defaultResponse(request);
  }

  http.Response defaultResponse(http.Request request) {
    final path = request.url.path;
    if (request.url.path.endsWith('/context')) {
      return user.mustChangePassword
          ? json({}, 403)
          : json({'schemaVersion': 1, 'coreId': 'a' * 32, 'homeId': 'b' * 32});
    }

    if (request.method == 'GET' && path.endsWith('/admin/users')) {
      return json({'users': users});
    }
    if (request.method == 'GET' && path.endsWith('/admin/sessions')) {
      return json({
        'sessions': [adminDeviceJson(revoked: revoked)],
        'nextCursor': null,
      });
    }
    if (request.method == 'GET' && path.endsWith('/admin/audit')) {
      return json({
        'events': [adminEventJson('3')],
        'nextCursor': null,
      });
    }
    if (request.method == 'DELETE') {
      revoked = true;
      return http.Response('', 204);
    }
    final body = jsonDecode(request.body) as Map<String, dynamic>;
    if (request.method == 'POST' && path.endsWith('/admin/users')) {
      final created = adminUserJson(
        id: 'dddddddddddddddddddddddddddddddd',
        username: (body['username'] as String).toLowerCase(),
        role: body['role'] as String,
        mustChange: true,
      );
      users.add(created);
      return json({'user': created}, 201);
    }
    final parts = path.split('/');
    final id = parts[parts.length - (path.endsWith('/password') ? 2 : 1)];
    final existing = users.singleWhere((item) => item['id'] == id);
    if (body['expectedRevision'] != existing['revision']) {
      return json({
        'error': {'code': 'revision_conflict'},
      }, 409);
    }
    existing['revision'] = (existing['revision'] as int) + 1;
    if (path.endsWith('/password')) {
      existing['mustChangePassword'] = true;
    } else {
      existing['role'] = body['role'];
      existing['disabled'] = body['disabled'];
    }
    return json({'user': existing});
  }
}
