import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../../shared/network/server_bound_client.dart';
import '../../backup/data/backup_snapshot.dart';
import '../domain/server_models.dart';

class LarenorServerApi {
  LarenorServerApi({
    required this.endpoint,
    http.Client? client,
    this.timeout = const Duration(seconds: 20),
    DateTime Function()? clock,
  }) : _client = ServerBoundClient(baseUrl: endpoint.baseUrl, inner: client),
       _clock = clock ?? DateTime.now;

  static const maxJsonBytes = 2 * 1024 * 1024;
  final ServerEndpoint endpoint;
  final ServerBoundClient _client;
  final Duration timeout;
  final DateTime Function() _clock;
  final _pending = <Completer<void>>{};
  bool _closed = false;

  Future<void> health() async {
    final result = await request('GET', '/health');
    if (result?['service'] != 'larenor-server' || result?['apiVersion'] != 1) {
      throw const LarenorServerException('invalid_response');
    }
  }

  Future<ServerSession> login({
    required String username,
    required String password,
    required String deviceName,
  }) async {
    if (username.trim().isEmpty ||
        username.length > 128 ||
        password.isEmpty ||
        password.length > 1024 ||
        deviceName.trim().isEmpty ||
        deviceName.length > 128) {
      throw const LarenorServerException('invalid_request');
    }
    return _pair(
      await request(
        'POST',
        '/auth/login',
        body: {
          'username': username.trim(),
          'password': password,
          'deviceName': deviceName.trim(),
        },
      ),
    );
  }

  Future<ServerSession> refresh(String refreshToken) async => _pair(
    await request(
      'POST',
      '/auth/refresh',
      body: {'refreshToken': refreshToken},
    ),
  );

  Future<ServerUser> me(String accessToken) async => ServerUser.fromJson(
    serverObject(
      (await request('GET', '/auth/me', token: accessToken))!['user'],
    ),
  );

  Future<ServerSession> changePassword({
    required String accessToken,
    required String currentPassword,
    required String newPassword,
  }) async => _pair(
    await request(
      'POST',
      '/auth/password',
      token: accessToken,
      body: {'currentPassword': currentPassword, 'newPassword': newPassword},
    ),
  );

  Future<void> logout(ServerSession session) async {
    await request(
      'POST',
      '/auth/logout',
      token: session.accessToken,
      body: {'refreshToken': session.refreshToken},
      allowEmpty: true,
    );
  }

  Future<ServerVault> readVault(String accessToken) async =>
      ServerVault.fromJson(
        (await request('GET', '/vault', token: accessToken))!,
      );

  Future<ServerVault> writeVault({
    required String accessToken,
    required int expectedRevision,
    required BackupSnapshot snapshot,
  }) async {
    final document = {'version': 1, 'snapshot': snapshot.toJson()};
    // Apply the same privacy/version validation to both directions.
    ServerVault.fromJson({'revision': expectedRevision, 'document': document});
    return ServerVault.fromJson(
      (await request(
        'PUT',
        '/vault',
        token: accessToken,
        body: {'expectedRevision': expectedRevision, 'document': document},
      ))!,
    );
  }

  ServerSession _pair(Map<String, dynamic>? json) =>
      ServerSession.fromResponse(endpoint, serverObject(json), now: _clock());

  /// No automatic retries: even a timed-out write may have reached the server.
  Future<Map<String, dynamic>?> request(
    String method,
    String path, {
    String? token,
    Map<String, dynamic>? body,
    Map<String, String>? queryParameters,
    bool allowEmpty = false,
  }) async {
    if (_closed) throw const LarenorServerException('cancelled');
    var uri = endpoint.api(path);
    if (queryParameters != null && queryParameters.isNotEmpty) {
      const keys = {'userId', 'cursor', 'limit', 'platform', 'channel'};
      final readQuery =
          method == 'GET' &&
          !path.startsWith('/admin/plugins/jobs') &&
          queryParameters.length <= keys.length &&
          !queryParameters.entries.any(
            (entry) =>
                !keys.contains(entry.key) ||
                entry.value.length > 512 ||
                entry.value.contains(RegExp(r'[\x00-\x1f\x7f]')),
          );
      final jobsList = path == '/admin/plugins/jobs';
      final jobsEvents = RegExp(r'^/admin/plugins/jobs/[0-9a-f]{32}/events$')
          .hasMatch(path);
      final jobsQuery =
          method == 'GET' &&
          (jobsList || jobsEvents) &&
          queryParameters.entries.every((entry) {
            final number = int.tryParse(entry.value);
            if (number == null ||
                number > 9223372036854775807 ||
                !RegExp(r'^(0|[1-9][0-9]{0,18})$').hasMatch(entry.value)) {
              return false;
            }
            return switch (entry.key) {
              'limit' => number >= 1 && number <= 100,
              'before' => jobsList && number >= 1,
              'after' => jobsEvents && number >= 0,
              _ => false,
            };
          });
      final revision = queryParameters['expectedRevision'];
      final revisionNumber = int.tryParse(revision ?? '');
      final forgetQuery =
          method == 'DELETE' &&
          RegExp(r'^/admin/services/[0-9a-f]{32}$').hasMatch(path) &&
          queryParameters.length == 1 &&
          revision != null &&
          RegExp(r'^[1-9][0-9]{0,18}$').hasMatch(revision) &&
          revisionNumber != null &&
          revisionNumber < 9223372036854775807;
      if (!readQuery && !forgetQuery && !jobsQuery) {
        throw const LarenorServerException('invalid_request');
      }
      uri = uri.replace(queryParameters: Map.of(queryParameters));
    }
    final abort = Completer<void>();
    _pending.add(abort);
    final timer = Timer(timeout, () {
      if (!abort.isCompleted) abort.complete();
    });
    try {
      final request = http.AbortableRequest(
        method,
        uri,
        abortTrigger: abort.future,
      )..headers['accept'] = 'application/json';
      if (token != null) request.headers['authorization'] = 'Bearer $token';
      if (body != null) {
        final bytes = utf8.encode(jsonEncode(body));
        if (bytes.length > maxJsonBytes) {
          throw const LarenorServerException('payload_too_large');
        }
        request.headers['content-type'] = 'application/json';
        request.bodyBytes = bytes;
      }
      final result = await _read(request, allowEmpty).timeout(timeout);
      if (_closed || abort.isCompleted) {
        throw const LarenorServerException('cancelled');
      }
      return result;
    } on LarenorServerException {
      rethrow;
    } on TimeoutException {
      throw const LarenorServerException('timeout');
    } on http.RequestAbortedException {
      throw LarenorServerException(_closed ? 'cancelled' : 'timeout');
    } catch (_) {
      throw LarenorServerException(
        _closed
            ? 'cancelled'
            : abort.isCompleted
            ? 'timeout'
            : 'connection_failed',
      );
    } finally {
      timer.cancel();
      if (!abort.isCompleted) abort.complete();
      _pending.remove(abort);
    }
  }

  Future<Map<String, dynamic>?> _read(
    http.BaseRequest request,
    bool allowEmpty,
  ) async {
    final response = await _client.send(request);
    final isSuccess = response.statusCode >= 200 && response.statusCode < 300;
    final limit = isSuccess ? maxJsonBytes : 8192;
    if ((response.contentLength ?? 0) > limit) {
      unawaited(
        response.stream.listen((_) {}).cancel().catchError((Object _) {}),
      );
      throw const LarenorServerException('invalid_response');
    }
    final bytes = <int>[];
    await for (final chunk in response.stream) {
      if (bytes.length + chunk.length > limit) {
        throw const LarenorServerException('invalid_response');
      }
      bytes.addAll(chunk);
    }
    if (!isSuccess) {
      throw LarenorServerException(_errorCode(response.statusCode, bytes));
    }
    if (response.statusCode == 204 && allowEmpty && bytes.isEmpty) return null;
    if (response.headers['content-type']?.split(';').first.trim() !=
        'application/json') {
      throw const LarenorServerException('invalid_response');
    }
    try {
      final json = jsonDecode(utf8.decode(bytes));
      var keys = 0;
      void check(Object? value, int depth) {
        if (depth > 16) throw const LarenorServerException('invalid_response');
        if (value is String && value.length > 65536) {
          throw const LarenorServerException('invalid_response');
        }
        if (value is Map) {
          keys += value.length;
          if (keys > 10000) {
            throw const LarenorServerException('invalid_response');
          }
          for (final entry in value.entries) {
            check(entry.key, depth + 1);
            check(entry.value, depth + 1);
          }
        } else if (value is List) {
          for (final item in value) {
            check(item, depth + 1);
          }
        }
      }

      check(json, 0);
      return serverObject(json);
    } catch (_) {
      throw const LarenorServerException('invalid_response');
    }
  }

  String _errorCode(int status, List<int> bytes) {
    // Only locally known codes are allowed through. Discard arbitrary messages.
    try {
      final code = (jsonDecode(utf8.decode(bytes)) as Map)['error']['code'];
      if (code == 'password_change_required' && status == 403) {
        return 'password_change_required';
      }
      if (code == 'self_password_reset_forbidden' && status == 403) {
        return 'self_password_reset_forbidden';
      }
      if (code == 'service_credentials_required' && status == 400) {
        return 'service_credentials_required';
      }
      if (status == 503 &&
          {
            'plugin_storage_unavailable',
            'plugin_worker_unavailable',
            'plugin_job_storage_unavailable',
          }.contains(code)) {
        return code as String;
      }
      if (status == 409 &&
          {
            'last_active_admin',
            'revision_conflict',
            'username_unavailable',
            'user_limit_reached',
            'service_limit_reached',
            'plugin_catalog_changed',
            'plugin_preview_expired',
            'plugin_preview_limit_reached',
            'plugin_job_conflict',
            'plugin_job_limit_reached',
          }.contains(code)) {
        return code as String;
      }
    } catch (_) {
      /* Untrusted proxy/server body. */
    }
    return switch (status) {
      400 || 422 => 'invalid_request',
      401 => 'unauthorized',
      403 => 'forbidden',
      409 => 'conflict',
      413 => 'payload_too_large',
      429 => 'rate_limited',
      _ => 'server_error',
    };
  }

  void close() {
    if (_closed) return;
    _closed = true;
    for (final abort in _pending) {
      if (!abort.isCompleted) abort.complete();
    }
    _client.close();
  }
}
