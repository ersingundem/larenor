import 'dart:async';
import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

import '../../../shared/network/server_bound_client.dart';
import 'managed_tablet_mqtt_runtime.dart';

final _id = RegExp(r'^[0-9a-f]{32}$');
final _controlCharacter = RegExp(r'[\x00-\x1f\x7f]');

final class ManagedTabletBinding {
  ManagedTabletBinding({
    required this.serverBaseUrl,
    required this.coreId,
    required this.homeId,
    required this.accountId,
  }) {
    parseServerUrl(serverBaseUrl);
    if (!_id.hasMatch(coreId) ||
        !_id.hasMatch(homeId) ||
        accountId.isEmpty ||
        accountId.length > 128 ||
        accountId.contains(_controlCharacter)) {
      throw ArgumentError('invalid_managed_tablet_binding');
    }
  }

  final String serverBaseUrl, coreId, homeId, accountId;

  @override
  bool operator ==(Object other) =>
      other is ManagedTabletBinding &&
      serverBaseUrl == other.serverBaseUrl &&
      coreId == other.coreId &&
      homeId == other.homeId &&
      accountId == other.accountId;

  @override
  int get hashCode => Object.hash(serverBaseUrl, coreId, homeId, accountId);

  @override
  String toString() => 'ManagedTabletBinding(redacted)';
}

/// Pairing material accepted from a trusted managed-device enrollment flow.
///
/// The token is intentionally absent from [publicMetadata] and [toString]. The
/// production persistence writes the complete record only to platform secure
/// storage; it is not a configuration or backup record.
final class ManagedTabletEnrollment {
  ManagedTabletEnrollment({
    required this.serverBaseUrl,
    required this.coreId,
    required this.homeId,
    required this.accountId,
    required this.pairingId,
    required this.deviceId,
    required this.revision,
    required Set<String> scopes,
    required this.expiresAt,
    required String token,
    required this.clientId,
    required this.topicPrefix,
  }) : scopes = Set.unmodifiable(scopes),
       // Public callers should never need to name a private field.
       // ignore: prefer_initializing_formals
       _token = token {
    binding;
    credential;
  }

  final String serverBaseUrl,
      coreId,
      homeId,
      accountId,
      pairingId,
      deviceId,
      clientId,
      topicPrefix;
  final int revision;
  final Set<String> scopes;
  final DateTime expiresAt;
  final String _token;

  ManagedTabletBinding get binding => ManagedTabletBinding(
    serverBaseUrl: serverBaseUrl,
    coreId: coreId,
    homeId: homeId,
    accountId: accountId,
  );

  ManagedTabletPairingCredential get credential =>
      ManagedTabletPairingCredential(
        pairingId: pairingId,
        deviceId: deviceId,
        revision: revision,
        scopes: scopes,
        expiresAt: expiresAt,
        active: true,
        token: _token,
        clientId: clientId,
        topicPrefix: topicPrefix,
      );

  Map<String, Object> get publicMetadata => {
    'schemaVersion': 1,
    'serverBaseUrl': serverBaseUrl,
    'binding': binding.toString(),
    ...credential.publicMetadata,
  };

  Map<String, Object> _storageJson() => {
    'schemaVersion': 1,
    'serverBaseUrl': serverBaseUrl,
    'coreId': coreId,
    'homeId': homeId,
    'accountId': accountId,
    'pairingId': pairingId,
    'deviceId': deviceId,
    'revision': revision,
    'scopes': scopes.toList()..sort(),
    'expiresAt': expiresAt.toUtc().toIso8601String(),
    'token': _token,
    'clientId': clientId,
    'topicPrefix': topicPrefix,
  };

  static ManagedTabletEnrollment _fromStorage(Object? raw) {
    const keys = {
      'schemaVersion',
      'serverBaseUrl',
      'coreId',
      'homeId',
      'accountId',
      'pairingId',
      'deviceId',
      'revision',
      'scopes',
      'expiresAt',
      'token',
      'clientId',
      'topicPrefix',
    };
    if (raw is! Map<String, dynamic> ||
        raw.length != keys.length ||
        !raw.keys.every(keys.contains) ||
        raw['schemaVersion'] != 1 ||
        raw['serverBaseUrl'] is! String ||
        raw['coreId'] is! String ||
        raw['homeId'] is! String ||
        raw['accountId'] is! String ||
        raw['pairingId'] is! String ||
        raw['deviceId'] is! String ||
        raw['revision'] is! int ||
        raw['scopes'] is! List ||
        raw['expiresAt'] is! String ||
        raw['token'] is! String ||
        raw['clientId'] is! String ||
        raw['topicPrefix'] is! String) {
      throw const FormatException('invalid_managed_tablet_enrollment');
    }
    final scopes = (raw['scopes'] as List).whereType<String>().toList();
    final expiresAt = DateTime.tryParse(raw['expiresAt'] as String);
    if (scopes.length != (raw['scopes'] as List).length ||
        scopes.toSet().length != scopes.length ||
        expiresAt == null ||
        !expiresAt.isUtc) {
      throw const FormatException('invalid_managed_tablet_enrollment');
    }
    try {
      return ManagedTabletEnrollment(
        serverBaseUrl: raw['serverBaseUrl'] as String,
        coreId: raw['coreId'] as String,
        homeId: raw['homeId'] as String,
        accountId: raw['accountId'] as String,
        pairingId: raw['pairingId'] as String,
        deviceId: raw['deviceId'] as String,
        revision: raw['revision'] as int,
        scopes: scopes.toSet(),
        expiresAt: expiresAt,
        token: raw['token'] as String,
        clientId: raw['clientId'] as String,
        topicPrefix: raw['topicPrefix'] as String,
      );
    } on ArgumentError {
      throw const FormatException('invalid_managed_tablet_enrollment');
    }
  }

  @override
  String toString() => 'ManagedTabletEnrollment($publicMetadata)';

  T _useToken<T>(T Function(String token) operation) => operation(_token);
}

final class ManagedTabletRevoked implements Exception {
  const ManagedTabletRevoked();
  @override
  String toString() => 'ManagedTabletRevoked';
}

abstract interface class ManagedTabletCoreAuthority {
  Future<void> verify(
    ManagedTabletBinding binding,
    ManagedTabletEnrollment enrollment,
  );
}

/// Revalidates the persisted pairing against its exact Core over a bounded,
/// redirect-denying transport. The pairing token is an HTTP header only.
final class CoreManagedTabletAuthority implements ManagedTabletCoreAuthority {
  CoreManagedTabletAuthority({
    http.Client Function()? client,
    this.timeout = const Duration(seconds: 20),
  }) : _client = client ?? http.Client.new;

  static const maxResponseBytes = 64 * 1024;
  final http.Client Function() _client;
  final Duration timeout;

  @override
  Future<void> verify(
    ManagedTabletBinding binding,
    ManagedTabletEnrollment enrollment,
  ) async {
    if (binding != enrollment.binding ||
        timeout <= Duration.zero ||
        timeout > const Duration(minutes: 1)) {
      throw StateError('managed_tablet_authority_denied');
    }
    final inner = _client();
    final client = ServerBoundClient(
      baseUrl: binding.serverBaseUrl,
      inner: inner,
    );
    final elapsed = Stopwatch()..start();
    try {
      final base = parseServerUrl(binding.serverBaseUrl);
      final uri = base.replace(
        path:
            '${base.path}/api/v1/admin/paired-remote/'
            '${binding.coreId}/${binding.homeId}/pairings/'
            '${enrollment.pairingId}/mqtt/discovery',
      );
      final request = http.Request('GET', uri);
      enrollment._useToken(
        (token) => request.headers['X-Larenor-Pairing-Token'] = token,
      );
      final response = await client.send(request).timeout(_remaining(elapsed));
      if ({401, 403, 404, 409}.contains(response.statusCode)) {
        await response.stream.listen((_) {}).cancel();
        throw const ManagedTabletRevoked();
      }
      if (response.statusCode != 200 ||
          response.headers['content-type']?.split(';').first.trim() !=
              'application/json' ||
          (response.contentLength ?? 0) > maxResponseBytes) {
        await response.stream.listen((_) {}).cancel();
        throw StateError('managed_tablet_authority_unavailable');
      }
      final bytes = await _readBounded(response.stream, elapsed);
      final raw = jsonDecode(utf8.decode(bytes, allowMalformed: false));
      _validateDiscovery(raw, enrollment);
    } on ManagedTabletRevoked {
      rethrow;
    } on TimeoutException {
      throw StateError('managed_tablet_authority_unavailable');
    } on FormatException {
      throw StateError('managed_tablet_authority_unavailable');
    } on http.ClientException {
      throw StateError('managed_tablet_authority_unavailable');
    } finally {
      client.close();
    }
  }

  Duration _remaining(Stopwatch elapsed) {
    final remaining = timeout - elapsed.elapsed;
    if (remaining <= Duration.zero) throw TimeoutException('authority');
    return remaining;
  }

  Future<List<int>> _readBounded(
    Stream<List<int>> stream,
    Stopwatch elapsed,
  ) async {
    final bytes = <int>[];
    final iterator = StreamIterator(stream);
    try {
      while (await iterator.moveNext().timeout(_remaining(elapsed))) {
        final chunk = iterator.current;
        if (bytes.length + chunk.length > maxResponseBytes) {
          throw StateError('managed_tablet_authority_unavailable');
        }
        bytes.addAll(chunk);
      }
      return bytes;
    } finally {
      await iterator.cancel();
    }
  }

  static void _validateDiscovery(
    Object? raw,
    ManagedTabletEnrollment enrollment,
  ) {
    const keys = {
      'schemaVersion',
      'pairingId',
      'deviceId',
      'pairingRevision',
      'listenerEnabled',
      'commandRetainAllowed',
      'availabilityTopic',
      'commandTopic',
      'ackTopic',
      'sensors',
    };
    if (raw is! Map<String, dynamic> ||
        raw.length != keys.length ||
        !raw.keys.every(keys.contains) ||
        raw['schemaVersion'] != 1 ||
        raw['pairingId'] != enrollment.pairingId ||
        raw['deviceId'] != enrollment.deviceId ||
        raw['pairingRevision'] != enrollment.revision ||
        raw['listenerEnabled'] != false ||
        raw['commandRetainAllowed'] != false ||
        raw['availabilityTopic'] != '${enrollment.topicPrefix}/availability' ||
        raw['commandTopic'] != '${enrollment.topicPrefix}/command' ||
        raw['ackTopic'] != '${enrollment.topicPrefix}/ack') {
      throw const FormatException('invalid_managed_tablet_discovery');
    }
    final sensors = raw['sensors'];
    const expected = {
      'battery',
      'network',
      'app_version',
      'app_foreground',
      'kiosk_state',
    };
    if (sensors is! List || sensors.length != expected.length) {
      throw const FormatException('invalid_managed_tablet_discovery');
    }
    final observed = <String>{};
    for (final item in sensors) {
      if (item is! Map<String, dynamic> ||
          item.length != 3 ||
          item['kind'] is! String ||
          item['stateTopic'] !=
              '${enrollment.topicPrefix}/sensor/${item['kind']}/state' ||
          item['retained'] != true) {
        throw const FormatException('invalid_managed_tablet_discovery');
      }
      observed.add(item['kind'] as String);
    }
    if (observed.length != sensors.length ||
        !observed.containsAll(expected) ||
        !expected.containsAll(observed)) {
      throw const FormatException('invalid_managed_tablet_discovery');
    }
  }
}

abstract interface class ManagedTabletCredentialStore {
  Future<ManagedTabletEnrollment?> read();
  Future<void> write(ManagedTabletEnrollment value);
  Future<void> clearIfCurrent(ManagedTabletBinding binding, String pairingId);
}

final class SecureManagedTabletCredentialStore
    implements ManagedTabletCredentialStore {
  SecureManagedTabletCredentialStore({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  static const key = 'kiosk_remote_managed_tablet_credential_v1';
  final FlutterSecureStorage _storage;
  Future<void> _serial = Future.value();

  Future<T> _run<T>(Future<T> Function() operation) {
    final next = _serial.then((_) => operation());
    _serial = next.then<void>((_) {}, onError: (_, _) {});
    return next;
  }

  @override
  Future<ManagedTabletEnrollment?> read() => _run(() async {
    try {
      final raw = await _storage.read(key: key);
      if (raw == null) return null;
      return ManagedTabletEnrollment._fromStorage(jsonDecode(raw));
    } on FormatException {
      rethrow;
    } catch (_) {
      throw StateError('managed_tablet_credential_read_failed');
    }
  });

  @override
  Future<void> write(ManagedTabletEnrollment value) => _run(() async {
    try {
      await _storage.write(key: key, value: jsonEncode(value._storageJson()));
    } catch (_) {
      throw StateError('managed_tablet_credential_write_unconfirmed');
    }
  });

  @override
  Future<void> clearIfCurrent(ManagedTabletBinding binding, String pairingId) =>
      _run(() async {
        try {
          final raw = await _storage.read(key: key);
          if (raw == null) return;
          final current = ManagedTabletEnrollment._fromStorage(jsonDecode(raw));
          if (current.binding == binding && current.pairingId == pairingId) {
            await _storage.delete(key: key);
          }
        } on FormatException {
          rethrow;
        } catch (_) {
          throw StateError('managed_tablet_credential_clear_unconfirmed');
        }
      });

  @override
  String toString() => 'SecureManagedTabletCredentialStore(redacted)';
}
