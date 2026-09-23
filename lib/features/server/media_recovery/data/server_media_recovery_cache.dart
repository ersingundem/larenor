import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../../../../core/configuration_writes.dart';
import '../../domain/server_models.dart';
import '../domain/server_media_recovery_models.dart';

abstract interface class ServerMediaRecoveryCacheBackend {
  Future<String?> read();
  Future<bool> compareAndWrite(
    String? expected,
    String value, {
    required bool Function() current,
  });
  Future<bool> compareAndClear(String expected);
}

final class SharedPreferencesServerMediaRecoveryCacheBackend
    implements ServerMediaRecoveryCacheBackend {
  SharedPreferencesServerMediaRecoveryCacheBackend({
    Future<SharedPreferences> Function()? loadPreferences,
  }) : _loadPreferences = loadPreferences ?? SharedPreferences.getInstance;

  static const key = 'server_media_recovery_cache_v1';
  final Future<SharedPreferences> Function() _loadPreferences;

  @override
  Future<String?> read() => ConfigurationWrites.run(() async {
    final preferences = await _loadPreferences();
    await preferences.reload();
    return preferences.getString(key);
  });

  @override
  Future<bool> compareAndWrite(
    String? expected,
    String value, {
    required bool Function() current,
  }) => ConfigurationWrites.run(() async {
    bool isCurrent() {
      try {
        return current();
      } catch (_) {
        return false;
      }
    }

    if (!isCurrent()) return false;
    final preferences = await _loadPreferences();
    if (!isCurrent()) return false;
    await preferences.reload();
    if (!isCurrent() || preferences.getString(key) != expected) return false;
    if (!await preferences.setString(key, value)) {
      throw StateError('media_recovery_cache_write_failed');
    }
    if (!isCurrent()) {
      await preferences.reload();
      if (preferences.getString(key) == value &&
          !await preferences.remove(key)) {
        throw StateError('media_recovery_cache_clear_failed');
      }
      return false;
    }
    return true;
  });

  @override
  Future<bool> compareAndClear(String expected) =>
      ConfigurationWrites.run(() async {
        final preferences = await _loadPreferences();
        await preferences.reload();
        if (preferences.getString(key) != expected) return false;
        if (!await preferences.remove(key)) {
          throw StateError('media_recovery_cache_clear_failed');
        }
        return true;
      });
}

final class ServerMediaRecoveryCacheScope {
  const ServerMediaRecoveryCacheScope({
    required this.coreId,
    required this.homeId,
    required this.accountId,
  });

  factory ServerMediaRecoveryCacheScope.fromSession(ServerSession session) {
    final context = session.context;
    if (context == null) {
      throw StateError('media_recovery_cache_scope_unavailable');
    }
    return ServerMediaRecoveryCacheScope(
      coreId: context.coreId,
      homeId: context.homeId,
      accountId: session.user.id,
    );
  }

  final String coreId, homeId, accountId;

  bool get valid =>
      RegExp(r'^[a-f0-9]{32}$').hasMatch(coreId) &&
      RegExp(r'^[a-f0-9]{32}$').hasMatch(homeId) &&
      accountId.isNotEmpty &&
      accountId.length <= 128 &&
      !accountId.contains(RegExp(r'[\x00-\x1f\x7f]'));

  Map<String, Object> toJson() => {
    'coreId': coreId,
    'homeId': homeId,
    'accountId': accountId,
  };

  @override
  String toString() => 'ServerMediaRecoveryCacheScope(redacted)';
}

final class ServerMediaRecoveryCache {
  ServerMediaRecoveryCache({
    ServerMediaRecoveryCacheBackend? backend,
    DateTime Function()? now,
  }) : _backend = backend ?? SharedPreferencesServerMediaRecoveryCacheBackend(),
       _now = now ?? DateTime.now;

  static const maximumBytes = 64 * 1024;
  static const timeToLive = Duration(minutes: 5);

  final ServerMediaRecoveryCacheBackend _backend;
  final DateTime Function() _now;

  Future<ServerMediaRecoveryStatus?> read(
    ServerMediaRecoveryCacheScope scope, {
    required bool Function() current,
  }) async {
    bool isCurrent() {
      try {
        return current();
      } catch (_) {
        return false;
      }
    }

    if (!isCurrent() || !scope.valid) return null;
    final String? raw;
    try {
      raw = await _backend.read();
    } catch (_) {
      return null;
    }
    if (!isCurrent() || raw == null) return null;
    if (raw.length > maximumBytes || utf8.encode(raw).length > maximumBytes) {
      await _clearIfCurrent(raw, isCurrent);
      return null;
    }
    try {
      final record = _object(jsonDecode(raw), {
        'schemaVersion',
        'scope',
        'resource',
        'savedAt',
        'status',
      });
      if (record['schemaVersion'] is! int || record['schemaVersion'] != 1) {
        throw const FormatException();
      }
      final storedScope = _object(record['scope'], {
        'coreId',
        'homeId',
        'accountId',
      });
      if (storedScope['coreId'] != scope.coreId ||
          storedScope['homeId'] != scope.homeId ||
          storedScope['accountId'] != scope.accountId) {
        return null;
      }
      final savedAt = record['savedAt'] is String
          ? DateTime.tryParse(record['savedAt'] as String)
          : null;
      final instant = _now().toUtc();
      if (savedAt == null ||
          !savedAt.isUtc ||
          savedAt.toIso8601String() != record['savedAt'] ||
          instant.isBefore(savedAt) ||
          !instant.isBefore(savedAt.add(timeToLive))) {
        throw const FormatException();
      }
      final status = ServerMediaRecoveryStatus.fromJson(record['status']);
      if (!_resourceMatches(record['resource'], status)) {
        throw const FormatException();
      }
      if (!isCurrent()) return null;
      return status;
    } catch (_) {
      await _clearIfCurrent(raw, isCurrent);
      return null;
    }
  }

  Future<bool> write(
    ServerMediaRecoveryCacheScope scope,
    ServerMediaRecoveryStatus status, {
    required bool Function() current,
  }) async {
    bool isCurrent() {
      try {
        return current();
      } catch (_) {
        return false;
      }
    }

    if (!isCurrent()) return false;
    if (!scope.valid) throw StateError('media_recovery_cache_scope_invalid');
    final canonical = ServerMediaRecoveryStatus.fromJson(status.toJson());
    final expected = await _backend.read();
    if (!isCurrent()) return false;
    final raw = jsonEncode({
      'schemaVersion': 1,
      'scope': scope.toJson(),
      'resource': _resourceJson(canonical),
      'savedAt': _now().toUtc().toIso8601String(),
      'status': canonical.toJson(),
    });
    if (raw.length > maximumBytes || utf8.encode(raw).length > maximumBytes) {
      throw StateError('media_recovery_cache_quota_exceeded');
    }
    if (!isCurrent()) return false;
    final written = await _backend.compareAndWrite(
      expected,
      raw,
      current: isCurrent,
    );
    if (!written) return false;
    if (!isCurrent()) {
      await _clearIfCurrent(raw, () => true);
      return false;
    }
    return true;
  }

  Future<void> _clearIfCurrent(String raw, bool Function() current) async {
    if (!current()) return;
    try {
      await _backend.compareAndClear(raw);
    } catch (_) {}
  }
}

Map<String, Object?> _resourceJson(ServerMediaRecoveryStatus status) => {
  'kind': 'media_recovery_status',
  'contractVersion': 2,
  'revisionVector': [
    for (final service in status.services)
      {
        'serviceId': service.serviceId,
        'sourceId': service.sourceId,
        'sourceKind': service.sourceKind,
        'revision': service.revision,
      },
  ],
};

bool _resourceMatches(Object? value, ServerMediaRecoveryStatus status) {
  final resource = _object(value, {
    'kind',
    'contractVersion',
    'revisionVector',
  });
  if (resource['kind'] != 'media_recovery_status' ||
      resource['contractVersion'] is! int ||
      resource['contractVersion'] != 2 ||
      resource['revisionVector'] is! List) {
    return false;
  }
  final vector = resource['revisionVector'] as List;
  if (vector.length != status.services.length) return false;
  for (var index = 0; index < vector.length; index++) {
    final item = _object(vector[index], {
      'serviceId',
      'sourceId',
      'sourceKind',
      'revision',
    });
    final service = status.services[index];
    if (item['serviceId'] != service.serviceId ||
        item['sourceId'] != service.sourceId ||
        item['sourceKind'] != service.sourceKind ||
        item['revision'] != service.revision ||
        (item['revision'] != null && item['revision'] is! int)) {
      return false;
    }
  }
  return true;
}

Map<String, dynamic> _object(Object? value, Set<String> keys) {
  if (value is! Map<String, dynamic> ||
      value.length != keys.length ||
      !value.keys.every(keys.contains)) {
    throw const FormatException('invalid_media_recovery_cache');
  }
  return value;
}
