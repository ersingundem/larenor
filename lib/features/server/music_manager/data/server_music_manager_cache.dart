import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../../../../core/configuration_writes.dart';
import '../../domain/server_models.dart';
import '../domain/server_music_manager_models.dart';

abstract interface class ServerMusicManagerCacheBackend {
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

final class SharedPreferencesServerMusicManagerCacheBackend
    implements ServerMusicManagerCacheBackend {
  SharedPreferencesServerMusicManagerCacheBackend({
    Future<SharedPreferences> Function()? loadPreferences,
  }) : _loadPreferences = loadPreferences ?? SharedPreferences.getInstance;

  static const key = 'server_music_manager_cache_v1';
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
      throw StateError('music_cache_write_failed');
    }
  });

  @override
  Future<bool> compareAndWrite(
    String? expected,
    String value, {
    required bool Function() current,
  }) => ConfigurationWrites.run(() async {
    if (!current()) return false;
    final preferences = await _loadPreferences();
    if (!current()) return false;
    await preferences.reload();
    if (!current() || preferences.getString(key) != expected) return false;
    if (!await preferences.setString(key, value)) {
      throw StateError('music_cache_write_failed');
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
          throw StateError('music_cache_clear_failed');
        }
        return true;
      });

  @override
  Future<void> clear() => ConfigurationWrites.run(() async {
    final preferences = await _loadPreferences();
    if (!await preferences.remove(key)) {
      throw StateError('music_cache_clear_failed');
    }
  });
}

final class ServerMusicManagerCacheScope {
  const ServerMusicManagerCacheScope({
    required this.coreId,
    required this.homeId,
    required this.accountId,
  });

  factory ServerMusicManagerCacheScope.fromSession(ServerSession session) {
    final context = session.context;
    if (context == null) throw StateError('music_cache_scope_unavailable');
    return ServerMusicManagerCacheScope(
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
      other is ServerMusicManagerCacheScope &&
      coreId == other.coreId &&
      homeId == other.homeId &&
      accountId == other.accountId;

  @override
  int get hashCode => Object.hash(coreId, homeId, accountId);

  @override
  String toString() => 'ServerMusicManagerCacheScope(redacted)';
}

final class ServerMusicManagerCache {
  ServerMusicManagerCache({
    ServerMusicManagerCacheBackend? backend,
    DateTime Function()? now,
  }) : _backend = backend ?? SharedPreferencesServerMusicManagerCacheBackend(),
       _now = now ?? DateTime.now;

  static const maximumBytes = 256 * 1024;
  static const timeToLive = Duration(minutes: 5);
  final ServerMusicManagerCacheBackend _backend;
  final DateTime Function() _now;

  Future<ServerMusicManager?> read(
    ServerMusicManagerCacheScope scope, {
    required String installationId,
    required int installationRevision,
    required int coreRevision,
  }) async {
    if (!scope.valid) return null;
    final String? raw;
    try {
      raw = await _backend.read();
    } catch (_) {
      return null;
    }
    if (raw == null) return null;
    if (utf8.encode(raw).length > maximumBytes) {
      await _clearIfCurrent(raw);
      return null;
    }
    try {
      final decoded = jsonDecode(raw);
      final record = _object(decoded, {
        'schemaVersion',
        'scope',
        'resource',
        'savedAt',
        'manager',
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
        'installationId',
        'installationRevision',
        'coreRevision',
        'managerRevision',
      });
      final storedInstallationRevision = resource['installationRevision'];
      final storedCoreRevision = resource['coreRevision'];
      final storedManagerRevision = resource['managerRevision'];
      if (resource['kind'] != 'music_manager' ||
          resource['installationId'] is! String ||
          storedInstallationRevision is! int ||
          storedInstallationRevision < 1 ||
          storedInstallationRevision > 0x7fffffffffffffff ||
          storedCoreRevision is! int ||
          storedCoreRevision < 1 ||
          storedCoreRevision > 0x7fffffffffffffff ||
          storedManagerRevision is! int ||
          storedManagerRevision < 1 ||
          storedManagerRevision > 0x7fffffffffffffff) {
        throw const FormatException();
      }
      if (resource['installationId'] != installationId ||
          storedInstallationRevision != installationRevision ||
          storedCoreRevision != coreRevision) {
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
      final manager = ServerMusicManager.fromJson(record['manager']);
      if (manager.installationId != installationId ||
          manager.installationRevision != installationRevision ||
          manager.coreRevision != coreRevision ||
          manager.revision != storedManagerRevision ||
          manager.updatedAt.isAfter(savedAt)) {
        throw const FormatException();
      }
      return manager;
    } catch (_) {
      await _clearIfCurrent(raw);
      return null;
    }
  }

  Future<bool> write(
    ServerMusicManagerCacheScope scope,
    ServerMusicManager manager, {
    bool Function()? isCurrent,
  }) async {
    bool current() {
      try {
        return isCurrent?.call() ?? true;
      } catch (_) {
        return false;
      }
    }

    if (!current()) return false;
    if (!scope.valid) throw StateError('music_cache_scope_invalid');
    final savedAt = _now().toUtc();
    if (manager.updatedAt.isAfter(savedAt)) {
      throw StateError('music_cache_time_invalid');
    }
    final expected = await _backend.read();
    if (!current()) return false;
    final raw = jsonEncode({
      'schemaVersion': 1,
      'scope': scope.toJson(),
      'resource': {
        'kind': 'music_manager',
        'installationId': manager.installationId,
        'installationRevision': manager.installationRevision,
        'coreRevision': manager.coreRevision,
        'managerRevision': manager.revision,
      },
      'savedAt': savedAt.toIso8601String(),
      'manager': manager.toJson(),
    });
    if (utf8.encode(raw).length > maximumBytes) {
      throw StateError('music_cache_quota_exceeded');
    }
    if (!current()) return false;
    return _backend.compareAndWrite(expected, raw, current: current);
  }

  Future<void> _clearIfCurrent(String raw) async {
    try {
      await _backend.compareAndClear(raw);
    } catch (_) {}
  }
}

Map<String, dynamic> _object(Object? value, Set<String> keys) {
  if (value is! Map<String, dynamic> ||
      value.length != keys.length ||
      !value.keys.every(keys.contains)) {
    throw const FormatException('invalid_music_cache');
  }
  return value;
}
