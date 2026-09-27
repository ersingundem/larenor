import 'dart:convert';
import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

import '../../../../core/configuration_writes.dart';
import '../../data/server_scoped_cache_backend.dart';
import '../../domain/server_models.dart';
import '../domain/server_music_retained_models.dart';

abstract interface class ServerMusicRetainedCacheBackend {
  Future<String?> read();
  Future<bool> compareAndWrite(
    String? expected,
    String value, {
    required bool Function() current,
  });
  Future<bool> compareAndClear(String expected);
}

final class SharedPreferencesServerMusicRetainedCacheBackend
    implements ServerMusicRetainedCacheBackend, ServerScopedStringCacheBackend {
  SharedPreferencesServerMusicRetainedCacheBackend({
    Future<SharedPreferences> Function()? loadPreferences,
  }) : _loadPreferences = loadPreferences ?? SharedPreferences.getInstance;

  static const key = 'server_music_retained_cache_v1';
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
      throw StateError('music_retained_cache_write_failed');
    }
    if (!isCurrent()) {
      await preferences.reload();
      if (preferences.getString(key) == value &&
          !await preferences.remove(key)) {
        throw StateError('music_retained_cache_clear_failed');
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
          throw StateError('music_retained_cache_clear_failed');
        }
        return true;
      });
  ServerScopedStringCacheBackend get _scoped =>
      SharedPreferencesScopedStringCache(_loadPreferences);

  @override
  Future<String?> readScoped(String key) => _scoped.readScoped(key);

  @override
  Future<void> writeScoped(String key, String value, String failureCode) =>
      _scoped.writeScoped(key, value, failureCode);

  @override
  Future<bool> compareAndWriteScoped(
    String key,
    String? expected,
    String value, {
    required bool Function() current,
    required String writeFailureCode,
    required String clearFailureCode,
  }) => _scoped.compareAndWriteScoped(
    key,
    expected,
    value,
    current: current,
    writeFailureCode: writeFailureCode,
    clearFailureCode: clearFailureCode,
  );

  @override
  Future<bool> compareAndClearScoped(
    String key,
    String expected,
    String failureCode,
  ) => _scoped.compareAndClearScoped(key, expected, failureCode);

  @override
  Future<void> clearScoped(String key, String failureCode) =>
      _scoped.clearScoped(key, failureCode);
}

final class ServerMusicRetainedCacheScope {
  const ServerMusicRetainedCacheScope({
    required this.coreId,
    required this.homeId,
    required this.accountId,
  });

  factory ServerMusicRetainedCacheScope.fromSession(ServerSession session) {
    final context = session.context;
    if (context == null) {
      throw StateError('music_retained_cache_scope_unavailable');
    }
    return ServerMusicRetainedCacheScope(
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
  String toString() => 'ServerMusicRetainedCacheScope(redacted)';
}

final class ServerMusicRetainedCache {
  ServerMusicRetainedCache({
    ServerMusicRetainedCacheBackend? backend,
    DateTime Function()? now,
    String Function()? recordId,
  }) : _backend = backend ?? SharedPreferencesServerMusicRetainedCacheBackend(),
       _now = now ?? DateTime.now,
       _recordId = recordId ?? _randomRecordId;

  static const maximumBytes = 64 * 1024;
  static const timeToLive = Duration(minutes: 5);

  final ServerMusicRetainedCacheBackend _backend;

  String _storageKey(ServerMusicRetainedCacheScope scope) =>
      serverScopedCacheKey(
        SharedPreferencesServerMusicRetainedCacheBackend.key,
        coreId: scope.coreId,
        homeId: scope.homeId,
        accountId: scope.accountId,
      );

  Future<String?> _readBackend(ServerMusicRetainedCacheScope scope) {
    final backend = _backend;
    if (backend is ServerScopedStringCacheBackend) {
      return (backend as ServerScopedStringCacheBackend).readScoped(
        _storageKey(scope),
      );
    }
    return backend.read();
  }

  Future<bool> _compareAndWrite(
    ServerMusicRetainedCacheScope scope,
    String? expected,
    String value, {
    required bool Function() current,
  }) {
    final backend = _backend;
    if (backend is ServerScopedStringCacheBackend) {
      return (backend as ServerScopedStringCacheBackend).compareAndWriteScoped(
        _storageKey(scope),
        expected,
        value,
        current: current,
        writeFailureCode: 'music_retained_cache_write_failed',
        clearFailureCode: 'music_retained_cache_clear_failed',
      );
    }
    return backend.compareAndWrite(expected, value, current: current);
  }

  Future<bool> _compareAndClear(
    ServerMusicRetainedCacheScope scope,
    String expected,
  ) {
    final backend = _backend;
    if (backend is ServerScopedStringCacheBackend) {
      return (backend as ServerScopedStringCacheBackend).compareAndClearScoped(
        _storageKey(scope),
        expected,
        'music_retained_cache_clear_failed',
      );
    }
    return backend.compareAndClear(expected);
  }

  final DateTime Function() _now;
  final String Function() _recordId;

  static String _randomRecordId() {
    final random = Random.secure();
    return List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }

  Future<ServerMusicRetainedOverview?> read(
    ServerMusicRetainedCacheScope scope, {
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
      raw = await _readBackend(scope);
    } catch (_) {
      return null;
    }
    if (!isCurrent() || raw == null) return null;
    if (raw.length > maximumBytes || utf8.encode(raw).length > maximumBytes) {
      await _clearIfCurrent(scope, raw, isCurrent);
      return null;
    }
    try {
      final record = _object(jsonDecode(raw), {
        'schemaVersion',
        'recordId',
        'scope',
        'resource',
        'savedAt',
        'overview',
      });
      if (record['schemaVersion'] is! int ||
          record['schemaVersion'] != 1 ||
          record['recordId'] is! String ||
          !RegExp(r'^[a-f0-9]{32}$').hasMatch(record['recordId'] as String)) {
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
      final overview = ServerMusicRetainedOverview.fromJson(record['overview']);
      if (!_resourceMatches(record['resource'], overview)) {
        throw const FormatException();
      }
      if (!isCurrent()) return null;
      return overview;
    } catch (_) {
      await _clearIfCurrent(scope, raw, isCurrent);
      return null;
    }
  }

  Future<bool> write(
    ServerMusicRetainedCacheScope scope,
    ServerMusicRetainedOverview overview, {
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
    if (!scope.valid) throw StateError('music_retained_cache_scope_invalid');
    final expected = await _readBackend(scope);
    if (!isCurrent()) return false;
    final recordId = _recordId();
    if (!RegExp(r'^[a-f0-9]{32}$').hasMatch(recordId)) {
      throw StateError('music_retained_cache_record_id_invalid');
    }
    final raw = jsonEncode({
      'schemaVersion': 1,
      'recordId': recordId,
      'scope': scope.toJson(),
      'resource': _resourceJson(overview),
      'savedAt': _now().toUtc().toIso8601String(),
      'overview': overview.toJson(),
    });
    if (raw.length > maximumBytes || utf8.encode(raw).length > maximumBytes) {
      throw StateError('music_retained_cache_quota_exceeded');
    }
    if (!isCurrent()) return false;
    final written = await _compareAndWrite(
      scope,
      expected,
      raw,
      current: isCurrent,
    );
    if (!written) return false;
    if (!isCurrent()) {
      await _clearIfCurrent(scope, raw, () => true);
      return false;
    }
    return true;
  }

  Future<void> _clearIfCurrent(
    ServerMusicRetainedCacheScope scope,
    String raw,
    bool Function() current,
  ) async {
    if (!current()) return;
    try {
      await _compareAndClear(scope, raw);
    } catch (_) {}
  }
}

Map<String, Object?> _resourceJson(ServerMusicRetainedOverview overview) => {
  'kind': 'music_retained_overview',
  'contractVersion': 1,
  'installations': [
    for (final installation in overview.installations)
      {
        'installationId': installation.installationId,
        'installationRevision': installation.installationRevision,
        'bootstrap': switch (installation.bootstrap) {
          null => null,
          final bootstrap => {
            'revision': bootstrap.revision,
            'schemaVersion': bootstrap.schemaVersion,
            'homeAssistant': bootstrap.homeAssistant.toJson(),
            'jellyfin': bootstrap.jellyfin.toJson(),
          },
        },
        'providers': [
          for (final provider in installation.providers)
            {'id': provider.id, 'revision': provider.revision},
        ],
      },
  ],
};

bool _resourceMatches(Object? value, ServerMusicRetainedOverview overview) {
  final resource = _object(value, {'kind', 'contractVersion', 'installations'});
  if (resource['kind'] != 'music_retained_overview' ||
      resource['contractVersion'] is! int ||
      resource['contractVersion'] != 1 ||
      resource['installations'] is! List) {
    return false;
  }
  final installations = resource['installations'] as List;
  if (installations.length != overview.installations.length) return false;
  for (var index = 0; index < installations.length; index++) {
    final stored = _object(installations[index], {
      'installationId',
      'installationRevision',
      'bootstrap',
      'providers',
    });
    final current = overview.installations[index];
    if (stored['installationId'] != current.installationId ||
        !_sameRevision(
          stored['installationRevision'],
          current.installationRevision,
        ) ||
        !_bootstrapMatches(stored['bootstrap'], current.bootstrap) ||
        !_providersMatch(stored['providers'], current.providers)) {
      return false;
    }
  }
  return true;
}

bool _bootstrapMatches(Object? value, ServerMusicBootstrapReceipt? current) {
  if (current == null) return value == null;
  final stored = _object(value, {
    'revision',
    'schemaVersion',
    'homeAssistant',
    'jellyfin',
  });
  return _sameRevision(stored['revision'], current.revision) &&
      _sameRevision(stored['schemaVersion'], current.schemaVersion) &&
      _serviceMatches(stored['homeAssistant'], current.homeAssistant) &&
      _serviceMatches(stored['jellyfin'], current.jellyfin);
}

bool _serviceMatches(Object? value, ServerMusicServiceRevision current) {
  final stored = _object(value, {'serviceId', 'serviceRevision'});
  return stored['serviceId'] == current.serviceId &&
      _sameRevision(stored['serviceRevision'], current.serviceRevision);
}

bool _providersMatch(Object? value, List<ServerMusicProviderStatus> current) {
  if (value is! List || value.length != current.length) return false;
  for (var index = 0; index < value.length; index++) {
    final stored = _object(value[index], {'id', 'revision'});
    if (stored['id'] != current[index].id ||
        !_sameRevision(stored['revision'], current[index].revision)) {
      return false;
    }
  }
  return true;
}

bool _sameRevision(Object? value, int current) =>
    value is int &&
    value >= 1 &&
    value <= 0x7fffffffffffffff &&
    value == current;

Map<String, dynamic> _object(Object? value, Set<String> keys) {
  if (value is! Map<String, dynamic> ||
      value.length != keys.length ||
      !value.keys.every(keys.contains)) {
    throw const FormatException('invalid_music_retained_cache');
  }
  return value;
}
