import 'dart:convert';
import 'dart:io';

import 'synthetic_core_resources.dart';
import 'synthetic_core_resource_admin.dart';

/// Minimal, opt-in Core account protocol for this process's loopback fixture.
/// No production account/API override, external service, or media write path.
class SyntheticCoreAccount {
  SyntheticCoreAccount({this.resources, this.adminResources}) {
    if (resources != null && adminResources != null) {
      throw ArgumentError('Choose one synthetic registry fixture.');
    }
  }
  final SyntheticCoreResources? resources;
  final SyntheticCoreResourceAdmin? adminResources;
  late final _emptyResources = SyntheticCoreResources.empty(userId: userId);
  static const username = 'fixture-core-user';
  static const password = 'Synthetic account password 2026';
  static const accessToken = 'synthetic-core-access-session';
  static const refreshToken = 'synthetic-core-refresh-session';
  String coreId = 'a' * 32;
  String homeId = 'b' * 32;
  String get userId => resources == null ? 'fixture-core-user-id' : 'e' * 32;
  int logins = 0;
  int meReads = 0;
  int contextReads = 0;
  int rejectedRequests = 0;

  Map<String, Object?> get user => {
    'id': userId,
    'username': username,
    'role': resources == null ? 'admin' : 'member',
    'mustChangePassword': false,
  };

  Future<void> handle(HttpRequest request) async {
    final response = request.response;
    response.headers.contentType = ContentType.json;
    void reject(int status) {
      rejectedRequests++;
      response.statusCode = status;
      response.write(jsonEncode({'error': 'fixture_rejected'}));
    }

    try {
      final path = request.uri.path;
      if (adminResources != null &&
          (path.startsWith('/api/v1/admin/home-resources/') ||
              path.startsWith('/api/v1/home-resources/'))) {
        final authorization = request.headers['authorization'];
        if (authorization == null ||
            authorization.length != 1 ||
            authorization.single != 'Bearer $accessToken') {
          reject(401);
        } else if (user['role'] != 'admin') {
          reject(403);
        } else {
          final (status, body) = await adminResources!.handle(
            request,
            coreId,
            homeId,
            userId,
          );
          if (status >= 400) rejectedRequests++;
          response.statusCode = status;
          if (body != null) response.write(jsonEncode(body));
        }
      } else if (path.startsWith('/api/v1/home-resources/')) {
        if (request.method != 'GET') {
          reject(403);
        } else if (request.headers.value('authorization') !=
            'Bearer $accessToken') {
          reject(401);
        } else if (path != '/api/v1/home-resources/$coreId/$homeId') {
          reject(404);
        } else {
          final (status, body) = (resources ?? _emptyResources).list(
            coreId,
            homeId,
            request.uri.queryParametersAll,
          );
          if (status != 200) rejectedRequests++;
          response.statusCode = status;
          response.write(jsonEncode(body));
        }
      } else if (request.uri.hasQuery) {
        reject(403);
      } else if (request.method == 'POST' && path == '/api/v1/auth/login') {
        final bytes = <int>[];
        await for (final chunk in request) {
          if (bytes.length + chunk.length > 4096) {
            reject(413);
            return;
          }
          bytes.addAll(chunk);
        }
        final Object? body;
        try {
          body = jsonDecode(utf8.decode(bytes));
        } on FormatException {
          reject(400);
          return;
        }
        if (body is! Map ||
            body.length != 3 ||
            body['username'] != username ||
            body['password'] != password ||
            body['deviceName'] is! String ||
            (body['deviceName'] as String).isEmpty ||
            (body['deviceName'] as String).length > 128) {
          reject(401);
        } else {
          logins++;
          response.write(
            jsonEncode({
              'accessToken': accessToken,
              'refreshToken': refreshToken,
              'expiresIn': 3600,
              'user': user,
            }),
          );
        }
      } else if (request.method == 'GET' && path == '/api/v1/health') {
        response.write(
          jsonEncode({'service': 'larenor-server', 'apiVersion': 1}),
        );
      } else if (request.method != 'GET' ||
          !{'/api/v1/auth/me', '/api/v1/context'}.contains(path)) {
        reject(403);
      } else if (request.headers.value('authorization') !=
          'Bearer $accessToken') {
        reject(401);
      } else if (path == '/api/v1/auth/me') {
        meReads++;
        response.write(jsonEncode({'user': user}));
      } else {
        contextReads++;
        response.write(
          jsonEncode({'schemaVersion': 1, 'coreId': coreId, 'homeId': homeId}),
        );
      }
    } finally {
      await response.close();
    }
  }
}
