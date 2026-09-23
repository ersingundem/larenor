import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import '../../../shared/network/server_bound_client.dart';
import '../../backup/data/backup_snapshot.dart';
import '../domain/server_models.dart';

abstract interface class LarenorBinaryDestination {
  Future<void> add(Uint8List bytes);
  Future<Uri> commit({required int byteLength, required String sha256});
  Future<void> cancel();
}

final class LarenorRequestSecret {
  LarenorRequestSecret._(this._bytes);

  factory LarenorRequestSecret.coreBackup(String value) {
    final bytes = utf8.encode(value);
    if (value.length < 16 ||
        value.length > 128 ||
        bytes.length > 512 ||
        value.contains(RegExp(r'[\x00-\x1f\x7f]'))) {
      throw const LarenorServerException('invalid_request');
    }
    return LarenorRequestSecret._(Uint8List.fromList(bytes));
  }

  Uint8List _bytes;
  bool get disposed => _bytes.isEmpty;

  Uint8List takeJsonBody(String key) {
    if (_bytes.isEmpty) throw const LarenorServerException('cancelled');
    final value = utf8.decode(_bytes, allowMalformed: false);
    final body = Uint8List.fromList(utf8.encode(jsonEncode({key: value})));
    dispose();
    return body;
  }

  void dispose() {
    _bytes.fillRange(0, _bytes.length, 0);
    _bytes = Uint8List(0);
  }

  @override
  String toString() => 'LarenorRequestSecret';
}

final class LarenorTransferCancellation {
  final Completer<void> _cancelled = Completer<void>();
  Future<void> get future => _cancelled.future;
  bool get isCancelled => _cancelled.isCompleted;
  void cancel() {
    if (!_cancelled.isCompleted) _cancelled.complete();
  }
}

final class LarenorBinaryReceipt {
  const LarenorBinaryReceipt({
    required this.destination,
    required this.byteLength,
    required this.sha256,
  });
  final Uri destination;
  final int byteLength;
  final String sha256;
  @override
  String toString() => 'LarenorBinaryReceipt($byteLength)';
}

final class _DigestCapture implements Sink<Digest> {
  Digest? value;
  @override
  void add(Digest data) => value = data;
  @override
  void close() {}
}

class LarenorServerApi {
  LarenorServerApi({
    required this.endpoint,
    http.Client? client,
    this.timeout = const Duration(seconds: 20),
    DateTime Function()? clock,
  }) : _client = ServerBoundClient(baseUrl: endpoint.baseUrl, inner: client),
       _clock = clock ?? DateTime.now;

  static const maxJsonBytes = 2 * 1024 * 1024;
  // Mirrors the Server contract: 128 MiB Core DB + 32 MiB family board +
  // 256 MiB component data + 8 MiB encrypted archive overhead.
  static const maxCoreBackupBytes = 424 * 1024 * 1024;
  static const coreBackupOverallTimeout = Duration(minutes: 15);
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

  Future<ServerContext> context(String accessToken) async =>
      ServerContext.fromJson(
        await request('GET', '/context', token: accessToken),
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

  /// Streams one encrypted Core backup to an OS-owned destination without a
  /// complete ciphertext buffer in Dart or the platform channel.
  Future<LarenorBinaryReceipt> exportCoreBackup({
    required String token,
    required LarenorRequestSecret passphrase,
    required LarenorBinaryDestination destination,
    required LarenorTransferCancellation cancellation,
  }) async {
    const maxBytes = maxCoreBackupBytes;
    const mediaType = 'application/vnd.larenor.core-backup';
    const disposition =
        'attachment; filename="larenor-core-backup.larenor-core"';
    const magic = [
      76,
      65,
      82,
      69,
      78,
      79,
      82,
      45,
      67,
      79,
      82,
      69,
      45,
      66,
      65,
      67,
      75,
      85,
      80,
      0,
      1,
    ];
    if (_closed || cancellation.isCancelled) {
      passphrase.dispose();
      await destination.cancel();
      throw const LarenorServerException('cancelled');
    }
    final abort = Completer<void>();
    var overallTimedOut = false;
    void abortRequest() {
      if (!abort.isCompleted) abort.complete();
    }

    Future<T> boundedPlatform<T>(Future<T> operation) => Future.any<T>([
      operation,
      cancellation.future.then<T>(
        (_) => throw const LarenorServerException('cancelled'),
      ),
    ]).timeout(timeout);
    Future<bool> moveNext(StreamIterator<List<int>> stream) =>
        Future.any<bool>([
          stream.moveNext(),
          abort.future.then(
            (_) => throw LarenorServerException(
              _closed || cancellation.isCancelled ? 'cancelled' : 'timeout',
            ),
          ),
        ]).timeout(timeout);
    unawaited(cancellation.future.then((_) => abortRequest()));
    _pending.add(abort);
    final timer = Timer(coreBackupOverallTimeout, () {
      overallTimedOut = true;
      abortRequest();
    });
    StreamIterator<List<int>>? iterator;
    var streamDone = false;
    var committed = false;
    try {
      final body = passphrase.takeJsonBody('passphrase');
      final request =
          http.AbortableRequest(
              'POST',
              endpoint.api('/admin/backups/export'),
              abortTrigger: abort.future,
            )
            ..headers['accept'] = mediaType
            ..headers['authorization'] = 'Bearer $token'
            ..headers['content-type'] = 'application/json'
            ..bodyBytes = body;
      late http.StreamedResponse response;
      try {
        response = await Future.any<http.StreamedResponse>([
          _client.send(request),
          abort.future.then(
            (_) => throw LarenorServerException(
              _closed || cancellation.isCancelled ? 'cancelled' : 'timeout',
            ),
          ),
        ]).timeout(timeout);
      } finally {
        // Request.bodyBytes may be a distinct copy. Clear both mutable buffers
        // as soon as request headers arrive or send terminates.
        body.fillRange(0, body.length, 0);
        final requestBody = request.bodyBytes;
        requestBody.fillRange(0, requestBody.length, 0);
      }
      iterator = StreamIterator(response.stream);
      final success = response.statusCode >= 200 && response.statusCode < 300;
      final limit = success ? maxBytes : 8192;
      if ((response.contentLength ?? 0) > limit) {
        throw const LarenorServerException('invalid_response');
      }
      if (!success) {
        final builder = BytesBuilder(copy: false);
        while (await moveNext(iterator)) {
          final chunk = iterator.current;
          if (builder.length + chunk.length > limit) {
            throw const LarenorServerException('invalid_response');
          }
          builder.add(chunk);
        }
        streamDone = true;
        throw LarenorServerException(
          _errorCode(response.statusCode, builder.takeBytes()),
        );
      }
      if (response.statusCode != 200 ||
          response.headers['content-type']?.split(';').first.trim() !=
              mediaType ||
          response.headers['content-disposition'] != disposition ||
          response.headers['cache-control'] != 'no-store' ||
          response.headers['x-content-type-options'] != 'nosniff') {
        throw const LarenorServerException('invalid_response');
      }
      final digestOutput = _DigestCapture();
      final digestInput = sha256.startChunkedConversion(digestOutput);
      var received = 0;
      while (await moveNext(iterator)) {
        if (_closed || abort.isCompleted || cancellation.isCancelled) {
          throw const LarenorServerException('cancelled');
        }
        final chunk = iterator.current;
        if (received + chunk.length > maxBytes) {
          throw const LarenorServerException('invalid_response');
        }
        for (
          var offset = 0;
          offset < chunk.length && received + offset < magic.length;
          offset++
        ) {
          if (chunk[offset] != magic[received + offset]) {
            throw const LarenorServerException('invalid_response');
          }
        }
        digestInput.add(chunk);
        for (var offset = 0; offset < chunk.length; offset += 64 * 1024) {
          final end = (offset + 64 * 1024).clamp(0, chunk.length);
          final part = chunk is Uint8List
              ? Uint8List.sublistView(chunk, offset, end)
              : Uint8List.fromList(chunk.sublist(offset, end));
          await boundedPlatform(destination.add(part));
          if (_closed || abort.isCompleted || cancellation.isCancelled) {
            throw const LarenorServerException('cancelled');
          }
        }
        received += chunk.length;
      }
      streamDone = true;
      digestInput.close();
      if (received < magic.length + 16 + 12 + 16 ||
          received > maxBytes ||
          (response.contentLength != null &&
              response.contentLength != received)) {
        throw const LarenorServerException('invalid_response');
      }
      if (_closed || abort.isCompleted || cancellation.isCancelled) {
        throw const LarenorServerException('cancelled');
      }
      final digest = digestOutput.value!.toString();
      final uri = await boundedPlatform(
        destination.commit(byteLength: received, sha256: digest),
      );
      committed = true;
      return LarenorBinaryReceipt(
        destination: uri,
        byteLength: received,
        sha256: digest,
      );
    } on LarenorServerException {
      rethrow;
    } on TimeoutException {
      throw LarenorServerException(
        _closed || cancellation.isCancelled ? 'cancelled' : 'timeout',
      );
    } on http.RequestAbortedException {
      throw LarenorServerException(
        _closed || cancellation.isCancelled ? 'cancelled' : 'timeout',
      );
    } catch (_) {
      throw LarenorServerException(
        _closed || cancellation.isCancelled
            ? 'cancelled'
            : overallTimedOut || abort.isCompleted
            ? 'timeout'
            : 'connection_failed',
      );
    } finally {
      passphrase.dispose();
      Future<void> terminal(Future<void> operation) async {
        try {
          await operation.timeout(timeout);
        } catch (_) {
          // Terminal cleanup cannot replace the bounded transport result.
        }
      }

      await Future.wait([
        if (!streamDone && iterator != null) terminal(iterator.cancel()),
        if (!committed) terminal(destination.cancel()),
      ]);
      timer.cancel();
      abortRequest();
      _pending.remove(abort);
    }
  }

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
    final homeResourceDeletion =
        method == 'DELETE' &&
        (path.startsWith('/admin/home-resources') ||
            path.startsWith('/admin/home-people'));
    bool canonicalRevision(String? raw) {
      if (raw == null || raw.length > 19) return false;
      final value = int.tryParse(raw);
      return value != null &&
          value >= 1 &&
          value <= 9223372036854775807 &&
          '$value' == raw;
    }

    final homeResourceDeleteQuery =
        homeResourceDeletion &&
        RegExp(
              r'^/admin/(?:home-resources|home-people)/[0-9a-f]{32}/[0-9a-f]{32}/[0-9a-f]{32}$',
            ).firstMatch(path)?.end ==
            path.length &&
        queryParameters?.length == 2 &&
        canonicalRevision(queryParameters?['expectedRevision']) &&
        canonicalRevision(queryParameters?['expectedAclRevision']);
    final tabletFleetDeletion =
        method == 'DELETE' &&
        RegExp(
          r'^/tablet-fleet/[0-9a-f]{32}/[0-9a-f]{32}/devices/[0-9a-f]{32}$',
        ).hasMatch(path);
    final tabletFleetDeleteQuery =
        tabletFleetDeletion &&
        queryParameters?.length == 1 &&
        canonicalRevision(queryParameters?['expectedRevision']);
    if (homeResourceDeletion && !homeResourceDeleteQuery) {
      throw const LarenorServerException('invalid_request');
    }
    if (tabletFleetDeletion && !tabletFleetDeleteQuery) {
      throw const LarenorServerException('invalid_request');
    }
    var uri = endpoint.api(path);
    if (queryParameters != null && queryParameters.isNotEmpty) {
      const keys = {'userId', 'cursor', 'limit', 'platform', 'channel'};
      final readQuery =
          tabletFleetDeleteQuery ||
          (method == 'GET' &&
              !path.startsWith('/admin/plugins/jobs') &&
              !path.startsWith('/admin/media/preparations') &&
              !path.startsWith('/admin/media/inspections') &&
              !path.startsWith('/home-resources') &&
              !path.startsWith('/home-people') &&
              !path.startsWith('/home-assistant') &&
              !path.startsWith('/admin/home-assistant') &&
              !path.startsWith('/admin/home-people') &&
              queryParameters.length <= keys.length &&
              !queryParameters.entries.any(
                (entry) =>
                    !keys.contains(entry.key) ||
                    entry.value.length > 512 ||
                    entry.value.contains(RegExp(r'[\x00-\x1f\x7f]')),
              ));
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
      final mediaQuery =
          method == 'GET' &&
          (path == '/admin/media/preparations' ||
              path == '/admin/media/inspections') &&
          queryParameters.entries.every((entry) {
            final number = int.tryParse(entry.value);
            if (number == null ||
                number > 9223372036854775807 ||
                !RegExp(r'^[1-9][0-9]{0,18}$').hasMatch(entry.value)) {
              return false;
            }
            return switch (entry.key) {
              'limit' => number <= 10,
              'before' => true,
              _ => false,
            };
          });
      final homeAssistantHistory =
          method == 'GET' &&
          RegExp(
            r'^/home-assistant/[0-9a-f]{32}/[0-9a-f]{32}/resources/[0-9a-f]{32}/history$',
          ).hasMatch(path) &&
          queryParameters.entries.every(
            (entry) => switch (entry.key) {
              'limit' =>
                RegExp(r'^[1-9][0-9]?$').hasMatch(entry.value) &&
                    (int.tryParse(entry.value) ?? 0) <= 50,
              'before' => RegExp(r'^[0-9a-f]{32}$').hasMatch(entry.value),
              _ => false,
            },
          );
      final homeAssistantEvents =
          method == 'GET' &&
          RegExp(
            r'^/home-assistant/[0-9a-f]{32}/[0-9a-f]{32}/resources/[0-9a-f]{32}/history/events$',
          ).hasMatch(path) &&
          queryParameters.entries.every((entry) {
            final number = int.tryParse(entry.value);
            if (number == null ||
                !RegExp(r'^[1-9][0-9]{0,3}$').hasMatch(entry.value)) {
              return false;
            }
            return switch (entry.key) {
              'limit' => number <= 50,
              'after' => number <= 2048,
              _ => false,
            };
          });
      final homeAssistantVerification =
          method == 'GET' &&
          RegExp(
            r'^/admin/home-assistant/[0-9a-f]{32}/[0-9a-f]{32}/history/verification$',
          ).hasMatch(path) &&
          queryParameters.length == 1 &&
          queryParameters.entries.every(
            (entry) =>
                entry.key == 'checkpoint' &&
                entry.value.isNotEmpty &&
                entry.value.length <= 512 &&
                !entry.value.contains(RegExp(r'[\x00-\x20\x7f-\xff]')),
          );
      final revision = queryParameters['expectedRevision'];
      final homeResourcesQuery =
          method == 'GET' &&
          RegExp(r'^/(?:home-resources|home-people)/[0-9a-f]{32}/[0-9a-f]{32}$')
              .hasMatch(path) &&
          (!queryParameters.containsKey('after') ||
              queryParameters.containsKey('expectedSnapshot')) &&
          queryParameters.entries.every(
            (entry) => switch (entry.key) {
              'limit' =>
                RegExp(r'^[1-9][0-9]{0,2}$').hasMatch(entry.value) &&
                    (int.tryParse(entry.value) ?? 0) <= 100,
              'after' => RegExp(r'^[0-9a-f]{32}$').hasMatch(entry.value),
              'expectedSnapshot' => RegExp(
                r'^[0-9a-f]{64}$',
              ).hasMatch(entry.value),
              _ => false,
            },
          );
      final homeDocumentsQuery =
          method == 'GET' &&
          RegExp(
            r'^/home-documents/[0-9a-f]{32}/[0-9a-f]{32}/(?:documents|reminders)$',
          ).hasMatch(path) &&
          queryParameters.entries.every(
            (entry) => switch (entry.key) {
              'query' =>
                path.endsWith('/documents') &&
                    entry.value.length <= 120 &&
                    !entry.value.contains(RegExp(r'[\x00-\x1f\x7f]')),
              'today' =>
                path.endsWith('/reminders') &&
                    RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(entry.value),
              'limit' =>
                RegExp(r'^[1-9][0-9]{0,2}$').hasMatch(entry.value) &&
                    (int.tryParse(entry.value) ?? 0) <= 100,
              _ => false,
            },
          );
      final keeneticDetailsQuery =
          method == 'GET' &&
          RegExp(
            r'^/keenetic/[0-9a-f]{32}/[0-9a-f]{32}/resources/[0-9a-f]{32}/details$',
          ).hasMatch(path) &&
          (!queryParameters.containsKey('after') ||
              queryParameters.containsKey('expectedSnapshot')) &&
          (!queryParameters.containsKey('expectedSnapshot') ||
              queryParameters.containsKey('after')) &&
          queryParameters.entries.every(
            (entry) => switch (entry.key) {
              'limit' =>
                RegExp(r'^[1-9][0-9]{0,2}$').hasMatch(entry.value) &&
                    (int.tryParse(entry.value) ?? 0) <= 100,
              'after' || 'expectedSnapshot' => RegExp(
                r'^[0-9a-f]{64}$',
              ).hasMatch(entry.value),
              _ => false,
            },
          );
      final revisionNumber = int.tryParse(revision ?? '');
      final localNotificationsQuery =
          method == 'GET' &&
          RegExp(
            r'^/local-notifications/[0-9a-f]{32}/[0-9a-f]{32}/subscriptions/[0-9a-f]{32}/events$',
          ).hasMatch(path) &&
          queryParameters.containsKey('expectedRevision') &&
          queryParameters.entries.every((entry) {
            final number = int.tryParse(entry.value);
            if (number == null ||
                !RegExp(r'^(0|[1-9][0-9]{0,18})$').hasMatch(entry.value) ||
                number > 0x7fffffffffffffff) {
              return false;
            }
            return switch (entry.key) {
              'expectedRevision' => number >= 1,
              'after' => number >= 0,
              'limit' => number >= 1 && number <= 100,
              _ => false,
            };
          });
      final forgetQuery =
          method == 'DELETE' &&
          RegExp(r'^/admin/services/[0-9a-f]{32}$').hasMatch(path) &&
          queryParameters.length == 1 &&
          revision != null &&
          RegExp(r'^[1-9][0-9]{0,18}$').hasMatch(revision) &&
          revisionNumber != null &&
          revisionNumber < 9223372036854775807;
      final personalProfileDeleteQuery =
          method == 'DELETE' &&
          RegExp(r'^/personal-profiles/[0-9a-f]{32}/[0-9a-f]{32}/[0-9a-f]{32}$')
              .hasMatch(path) &&
          queryParameters.length == 1 &&
          canonicalRevision(revision);
      final kioskRemoteDeleteQuery =
          method == 'DELETE' &&
          RegExp(
            r'^/admin/paired-remote/[0-9a-f]{32}/[0-9a-f]{32}/pairings/[0-9a-f]{32}$',
          ).hasMatch(path) &&
          queryParameters.length == 1 &&
          canonicalRevision(revision);
      if (!readQuery &&
          !forgetQuery &&
          !personalProfileDeleteQuery &&
          !kioskRemoteDeleteQuery &&
          !jobsQuery &&
          !mediaQuery &&
          !homeResourcesQuery &&
          !homeDocumentsQuery &&
          !keeneticDetailsQuery &&
          !homeAssistantHistory &&
          !homeAssistantEvents &&
          !homeAssistantVerification &&
          !localNotificationsQuery &&
          !homeResourceDeleteQuery) {
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
      if (response.statusCode == 404 &&
          request.method == 'GET' &&
          request.url == endpoint.api('/context')) {
        throw const LarenorServerException('context_endpoint_unavailable');
      }
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
      if (status == 404 && code == 'not_found' ||
          status == 408 && code == 'request_timeout' ||
          status == 409 &&
              {
                'ha_binding_changed',
                'ha_preview_invalid',
                'ha_command_conflict',
                'ha_migration_changed',
                'ha_migration_preview_invalid',
                'proxmox_binding_changed',
                'proxmox_preview_invalid',
                'keenetic_binding_changed',
                'keenetic_preview_invalid',
                'keenetic_snapshot_changed',
              }.contains(code) ||
          status == 429 &&
              {
                'ha_limit_reached',
                'ha_migration_limit_reached',
                'proxmox_limit_reached',
                'keenetic_limit_reached',
              }.contains(code) ||
          status == 502 &&
              {
                'ha_upstream_unauthorized',
                'ha_upstream_unavailable',
                'ha_projection_unsupported',
                'proxmox_summary_unsupported',
                'proxmox_upstream_unauthorized',
                'proxmox_upstream_unavailable',
                'keenetic_snapshot_unsupported',
                'keenetic_upstream_unauthorized',
                'keenetic_upstream_denied',
                'keenetic_upstream_unavailable',
                'keenetic_upstream_unsupported',
              }.contains(code)) {
        return code as String;
      }
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
            'media_preparation_storage_unavailable',
            'media_inspection_storage_unavailable',
            'media_archive_worker_unavailable',
            'sound_event_integrity_failed',
            'tablet_fleet_storage_unavailable',
            'energy_provider_unavailable',
            'energy_command_integrity_failed',
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
            'media_preparation_conflict',
            'media_preparation_changed',
            'media_inspection_conflict',
            'media_inspection_limit_reached',
            'media_catalog_changed',
            'media_context_changed',
            'media_preparation_limit_reached',
            'media_installation_changed',
            'media_archive_authority_changed',
            'media_archive_snapshot_stale',
            'notification_subscription_changed',
            'notification_subscription_inactive',
            'notification_registration_replay',
            'notification_not_delivered',
            'notification_event_conflict',
            'notification_limit_reached',
            'tablet_device_changed',
            'tablet_device_inactive',
            'tablet_profile_changed',
            'tablet_policy_changed',
            'tablet_registration_replay',
            'tablet_capability_unavailable',
            'tablet_command_conflict',
            'tablet_command_expired',
            'tablet_command_not_delivered',
            'tablet_command_changed',
            'tablet_limit_reached',
            'tablet_command_limit_reached',
          }.contains(code)) {
        return code as String;
      }
      if (status == 503 && code == 'notification_storage_unavailable') {
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
