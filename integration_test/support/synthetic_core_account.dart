import 'dart:convert';
import 'dart:io';

/// Minimal, opt-in Core account protocol for this process's loopback fixture.
/// No production account/API override, external service, or media write path.
class SyntheticCoreAccount {
  static const username = 'fixture-core-user';
  static const password = 'Synthetic account password 2026';
  static const accessToken = 'synthetic-core-access-session';
  static const refreshToken = 'synthetic-core-refresh-session';
  String coreId = 'a' * 32;
  String homeId = 'b' * 32;
  final userId = 'fixture-core-user-id';
  int logins = 0;
  int meReads = 0;
  int contextReads = 0;
  int rejectedRequests = 0;

  Map<String, Object?> get user => {
    'id': userId,
    'username': username,
    'role': 'admin',
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
      if (request.uri.hasQuery) {
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
