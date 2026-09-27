import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../../../../core/configuration_writes.dart';
import '../../data/server_scoped_cache_backend.dart';
import '../../domain/server_models.dart';
import '../domain/server_media_flow_models.dart';

abstract interface class ServerMediaFlowCacheBackend {
  Future<String?> read();
  Future<void> write(String value);
  Future<bool> compareAndWrite(
    String? expected,
    String value, {
    required bool Function() current,
  });
  Future<bool> compareAndClear(String expected);
  Future<void> clear();
}

final class SharedPreferencesServerMediaFlowCacheBackend
    implements ServerMediaFlowCacheBackend, ServerScopedStringCacheBackend {
  SharedPreferencesServerMediaFlowCacheBackend({
    Future<SharedPreferences> Function()? loadPreferences,
  }) : _loadPreferences = loadPreferences ?? SharedPreferences.getInstance;

  static const key = 'server_media_flow_cache_v1';
  final Future<SharedPreferences> Function() _loadPreferences;

  @override
  Future<String?> read() => ConfigurationWrites.run(() async {
    final preferences = await _loadPreferences();
    await preferences.reload();
    return preferences.getString(key);
  });

  @override
  Future<void> write(String value) => ConfigurationWrites.run(() async {
    final preferences = await _loadPreferences();
    if (!await preferences.setString(key, value)) {
      throw StateError('media_flow_cache_write_failed');
    }
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
    if (!isCurrent() || preferences.getString(key) != expected) {
      return false;
    }
    if (!await preferences.setString(key, value)) {
      throw StateError('media_flow_cache_write_failed');
    }
    if (!isCurrent()) {
      await preferences.reload();
      if (preferences.getString(key) == value &&
          !await preferences.remove(key)) {
        throw StateError('media_flow_cache_clear_failed');
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
          throw StateError('media_flow_cache_clear_failed');
        }
        return true;
      });

  @override
  Future<void> clear() => ConfigurationWrites.run(() async {
    final preferences = await _loadPreferences();
    if (!await preferences.remove(key)) {
      throw StateError('media_flow_cache_clear_failed');
    }
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

final class ServerMediaFlowCacheScope {
  const ServerMediaFlowCacheScope({
    required this.coreId,
    required this.homeId,
    required this.accountId,
  });

  factory ServerMediaFlowCacheScope.fromSession(ServerSession session) {
    final context = session.context;
    if (context == null) throw StateError('media_flow_cache_scope_unavailable');
    return ServerMediaFlowCacheScope(
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
  bool operator ==(Object other) =>
      other is ServerMediaFlowCacheScope &&
      coreId == other.coreId &&
      homeId == other.homeId &&
      accountId == other.accountId;

  @override
  int get hashCode => Object.hash(coreId, homeId, accountId);

  @override
  String toString() => 'ServerMediaFlowCacheScope(redacted)';
}

final class ServerMediaFlowCache {
  ServerMediaFlowCache({
    ServerMediaFlowCacheBackend? backend,
    DateTime Function()? now,
  }) : _backend = backend ?? SharedPreferencesServerMediaFlowCacheBackend(),
       _now = now ?? DateTime.now;

  static const maximumBytes = 256 * 1024;
  static const timeToLive = Duration(minutes: 2);
  final ServerMediaFlowCacheBackend _backend;

  String _storageKey(ServerMediaFlowCacheScope scope) => serverScopedCacheKey(
    SharedPreferencesServerMediaFlowCacheBackend.key,
    coreId: scope.coreId,
    homeId: scope.homeId,
    accountId: scope.accountId,
  );

  Future<String?> _readBackend(ServerMediaFlowCacheScope scope) {
    final backend = _backend;
    if (backend is ServerScopedStringCacheBackend) {
      return (backend as ServerScopedStringCacheBackend).readScoped(
        _storageKey(scope),
      );
    }
    return backend.read();
  }

  Future<bool> _compareAndWrite(
    ServerMediaFlowCacheScope scope,
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
        writeFailureCode: 'media_flow_cache_write_failed',
        clearFailureCode: 'media_flow_cache_clear_failed',
      );
    }
    return backend.compareAndWrite(expected, value, current: current);
  }

  Future<bool> _compareAndClear(
    ServerMediaFlowCacheScope scope,
    String expected,
  ) {
    final backend = _backend;
    if (backend is ServerScopedStringCacheBackend) {
      return (backend as ServerScopedStringCacheBackend).compareAndClearScoped(
        _storageKey(scope),
        expected,
        'media_flow_cache_clear_failed',
      );
    }
    return backend.compareAndClear(expected);
  }

  final DateTime Function() _now;

  Future<ServerMediaFlowStatus?> read(
    ServerMediaFlowCacheScope scope,
    ServerMediaFlowAuthority authority, {
    bool Function()? current,
  }) async {
    bool isCurrent() {
      try {
        return current?.call() ?? true;
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
        'scope',
        'resource',
        'savedAt',
        'flow',
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
      final resource = _object(record['resource'], {
        'kind',
        'mediaKey',
        'flowRevision',
        'sources',
      });
      final mediaKey = resource['mediaKey'];
      final flowRevision = resource['flowRevision'];
      if (resource['kind'] != 'media_flow' ||
          mediaKey is! String ||
          !validServerMediaKey(mediaKey) ||
          flowRevision is! int ||
          flowRevision < 1 ||
          flowRevision > 0x7fffffffffffffff) {
        throw const FormatException();
      }
      final resourceSources = _storedSources(resource['sources'], flowRevision);
      if (mediaKey != authority.mediaKey ||
          flowRevision != authority.flowRevision ||
          !_sourcesEqual(resourceSources, authority.sources)) {
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
      final flow = ServerMediaFlowStatus.fromJson(record['flow']);
      if (flow.mediaKey != authority.mediaKey ||
          flow.flowRevision != authority.flowRevision ||
          !_sourcesEqual(flow.sources, authority.sources) ||
          flow.sources.any(
            (source) => DateTime.fromMillisecondsSinceEpoch(
              source.observedAt * 1000,
              isUtc: true,
            ).isAfter(savedAt),
          )) {
        throw const FormatException();
      }
      if (!isCurrent()) return null;
      return flow;
    } catch (_) {
      await _clearIfCurrent(scope, raw, isCurrent);
      return null;
    }
  }

  Future<bool> write(
    ServerMediaFlowCacheScope scope,
    ServerMediaFlowStatus flow, {
    bool Function()? current,
  }) async {
    bool isCurrent() {
      try {
        return current?.call() ?? true;
      } catch (_) {
        return false;
      }
    }

    if (!isCurrent()) return false;
    if (!scope.valid) throw StateError('media_flow_cache_scope_invalid');
    final savedAt = _now().toUtc();
    if (flow.sources.any(
      (source) => DateTime.fromMillisecondsSinceEpoch(
        source.observedAt * 1000,
        isUtc: true,
      ).isAfter(savedAt),
    )) {
      throw StateError('media_flow_cache_time_invalid');
    }
    final expected = await _readBackend(scope);
    if (!isCurrent()) return false;
    final raw = jsonEncode({
      'schemaVersion': 1,
      'scope': scope.toJson(),
      'resource': {
        'kind': 'media_flow',
        'mediaKey': flow.mediaKey,
        'flowRevision': flow.flowRevision,
        'sources': [for (final source in flow.sources) source.toJson()],
      },
      'savedAt': savedAt.toIso8601String(),
      'flow': flow.toJson(),
    });
    if (raw.length > maximumBytes || utf8.encode(raw).length > maximumBytes) {
      throw StateError('media_flow_cache_quota_exceeded');
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
    ServerMediaFlowCacheScope scope,
    String raw,
    bool Function() current,
  ) async {
    if (!current()) return;
    try {
      await _compareAndClear(scope, raw);
    } catch (_) {}
  }
}

List<ServerMediaFlowSource> _storedSources(Object? value, int flowRevision) {
  if (value is! List || value.length != serverMediaFlowProviderOrder.length) {
    throw const FormatException();
  }
  final sources = value
      .map(ServerMediaFlowSource.fromJson)
      .toList(growable: false);
  for (var index = 0; index < sources.length; index++) {
    if (sources[index].provider != serverMediaFlowProviderOrder[index] ||
        sources[index].snapshotRevision != flowRevision) {
      throw const FormatException();
    }
  }
  return sources;
}

bool _sourcesEqual(
  List<ServerMediaFlowSource> left,
  List<ServerMediaFlowSource> right,
) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index++) {
    final a = left[index];
    final b = right[index];
    if (a.provider != b.provider ||
        a.serviceRevision != b.serviceRevision ||
        a.snapshotRevision != b.snapshotRevision ||
        a.observedAt != b.observedAt) {
      return false;
    }
  }
  return true;
}

Map<String, dynamic> _object(Object? value, Set<String> keys) {
  if (value is! Map<String, dynamic> ||
      value.length != keys.length ||
      !value.keys.every(keys.contains)) {
    throw const FormatException('invalid_media_flow_cache');
  }
  return value;
}
