import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../../../../core/configuration_writes.dart';
import '../../data/server_scoped_cache_backend.dart';
import '../../domain/server_models.dart';
import '../domain/server_music_manager_models.dart';

abstract interface class ServerMusicSelectionCacheBackend {
  Future<String?> read();
  Future<bool> compareAndWrite(String? expected, String value);
  Future<bool> compareAndClear(String expected);
  Future<void> clear();
}

final class SharedPreferencesServerMusicSelectionCacheBackend
    implements
        ServerMusicSelectionCacheBackend,
        ServerScopedStringCacheBackend {
  SharedPreferencesServerMusicSelectionCacheBackend({
    Future<SharedPreferences> Function()? loadPreferences,
  }) : _loadPreferences = loadPreferences ?? SharedPreferences.getInstance;

  static const key = 'server_music_selection_v1';
  final Future<SharedPreferences> Function() _loadPreferences;

  @override
  Future<String?> read() => ConfigurationWrites.run(() async {
    final preferences = await _loadPreferences();
    await preferences.reload();
    return preferences.getString(key);
  });

  @override
  Future<bool> compareAndWrite(String? expected, String value) =>
      ConfigurationWrites.run(() async {
        final preferences = await _loadPreferences();
        await preferences.reload();
        if (preferences.getString(key) != expected) return false;
        if (!await preferences.setString(key, value)) {
          throw StateError('music_selection_write_failed');
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
          throw StateError('music_selection_clear_failed');
        }
        return true;
      });

  @override
  Future<void> clear() => ConfigurationWrites.run(() async {
    final preferences = await _loadPreferences();
    if (!await preferences.remove(key)) {
      throw StateError('music_selection_clear_failed');
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

final class ServerMusicSelectionScope {
  const ServerMusicSelectionScope({
    required this.coreId,
    required this.homeId,
    required this.accountId,
  });

  factory ServerMusicSelectionScope.fromSession(ServerSession session) {
    final context = session.context;
    if (context == null) {
      throw StateError('music_selection_scope_unavailable');
    }
    return ServerMusicSelectionScope(
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
  String toString() => 'ServerMusicSelectionScope(redacted)';
}

final class ServerMusicSelection {
  const ServerMusicSelection._({
    required this.providerId,
    required this.receiverId,
  });

  final String providerId, receiverId;

  @override
  String toString() => 'ServerMusicSelection(redacted)';
}

/// Persists explicit central provider/player choices without retaining a
/// service address, credential, display name or mutable playback state.
final class ServerMusicSelectionCache {
  ServerMusicSelectionCache({
    ServerMusicSelectionCacheBackend? backend,
    DateTime Function()? now,
  }) : _backend =
           backend ?? SharedPreferencesServerMusicSelectionCacheBackend(),
       _now = now ?? DateTime.now;

  static const maximumBytes = 8 * 1024;
  static const timeToLive = Duration(days: 30);
  final ServerMusicSelectionCacheBackend _backend;
  final DateTime Function() _now;
  String? _lastWrittenKey;
  String? _lastWrittenValue;

  String _storageKey(ServerMusicSelectionScope scope) => serverScopedCacheKey(
    SharedPreferencesServerMusicSelectionCacheBackend.key,
    coreId: scope.coreId,
    homeId: scope.homeId,
    accountId: scope.accountId,
  );

  Future<String?> _readBackend(ServerMusicSelectionScope scope) {
    final backend = _backend;
    if (backend is ServerScopedStringCacheBackend) {
      return (backend as ServerScopedStringCacheBackend).readScoped(
        _storageKey(scope),
      );
    }
    return backend.read();
  }

  Future<bool> _compareAndWrite(
    ServerMusicSelectionScope scope,
    String? expected,
    String value,
  ) {
    final backend = _backend;
    if (backend is ServerScopedStringCacheBackend) {
      return (backend as ServerScopedStringCacheBackend).compareAndWriteScoped(
        _storageKey(scope),
        expected,
        value,
        current: () => true,
        writeFailureCode: 'music_selection_write_failed',
        clearFailureCode: 'music_selection_clear_failed',
      );
    }
    return backend.compareAndWrite(expected, value);
  }

  Future<bool> _compareAndClear(String key, String value) {
    final backend = _backend;
    if (backend is ServerScopedStringCacheBackend) {
      return (backend as ServerScopedStringCacheBackend).compareAndClearScoped(
        key,
        value,
        'music_selection_clear_failed',
      );
    }
    return backend.compareAndClear(value);
  }

  Future<ServerMusicSelection?> read(
    ServerMusicSelectionScope scope,
    ServerMusicManager manager,
  ) async {
    if (!scope.valid) return null;
    final String? raw;
    try {
      raw = await _readBackend(scope);
    } catch (_) {
      return null;
    }
    if (raw == null) return null;
    if (utf8.encode(raw).length > maximumBytes) {
      await _clearScopeIfCurrent(scope, raw);
      return null;
    }
    try {
      final record = _object(jsonDecode(raw), {
        'schemaVersion',
        'scope',
        'resource',
        'savedAt',
        'provider',
        'receiver',
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
      });
      final installationRevision = _revision(resource['installationRevision']);
      final coreRevision = _revision(resource['coreRevision']);
      if (resource['kind'] != 'music_selection' ||
          resource['installationId'] != manager.installationId ||
          installationRevision != manager.installationRevision ||
          coreRevision != manager.coreRevision) {
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
      final provider = _object(record['provider'], {
        'setupId',
        'revision',
        'domain',
        'instanceId',
      });
      final receiver = _object(record['receiver'], {
        'playerId',
        'provider',
        'kind',
        'groupMembers',
        'queueId',
      });
      final providerId = _bounded(provider['setupId'], 128);
      final providerRevision = _revision(provider['revision']);
      final providerDomain = _bounded(provider['domain'], 64);
      final providerInstanceId = _bounded(provider['instanceId'], 128);
      final receiverId = _bounded(receiver['playerId'], 128);
      final receiverProvider = _bounded(receiver['provider'], 128);
      final receiverKind = _bounded(receiver['kind'], 32);
      final groupMembers = _strings(receiver['groupMembers']);
      final queueId = receiver['queueId'] == null
          ? null
          : _bounded(receiver['queueId'], 128);
      final currentProvider = manager.providers
          .where(
            (item) =>
                item.setupId == providerId &&
                item.revision == providerRevision &&
                item.domain == providerDomain &&
                item.instanceId == providerInstanceId,
          )
          .firstOrNull;
      final currentReceiver = manager.receivers
          .where(
            (item) =>
                item.id == receiverId &&
                item.provider == receiverProvider &&
                item.kind == receiverKind &&
                _sameStrings(item.groupMembers, groupMembers) &&
                item.queueId == queueId &&
                item.available &&
                item.enabled,
          )
          .firstOrNull;
      if (currentProvider == null || currentReceiver == null) {
        throw const FormatException();
      }
      return ServerMusicSelection._(
        providerId: currentProvider.setupId,
        receiverId: currentReceiver.id,
      );
    } catch (_) {
      await _clearScopeIfCurrent(scope, raw);
      return null;
    }
  }

  Future<String?> write(
    ServerMusicSelectionScope scope,
    ServerMusicManager manager, {
    required ServerMusicProviderBinding provider,
    required ServerMusicReceiver receiver,
  }) async {
    if (!scope.valid ||
        !manager.providers.any((item) => _sameProvider(item, provider)) ||
        !manager.receivers.any((item) => _sameReceiver(item, receiver)) ||
        !receiver.available ||
        !receiver.enabled) {
      throw StateError('music_selection_invalid');
    }
    final expected = await _readBackend(scope);
    final raw = jsonEncode({
      'schemaVersion': 1,
      'scope': scope.toJson(),
      'resource': {
        'kind': 'music_selection',
        'installationId': manager.installationId,
        'installationRevision': manager.installationRevision,
        'coreRevision': manager.coreRevision,
      },
      'savedAt': _now().toUtc().toIso8601String(),
      'provider': {
        'setupId': provider.setupId,
        'revision': provider.revision,
        'domain': provider.domain,
        'instanceId': provider.instanceId,
      },
      'receiver': {
        'playerId': receiver.id,
        'provider': receiver.provider,
        'kind': receiver.kind,
        'groupMembers': receiver.groupMembers,
        'queueId': receiver.queueId,
      },
    });
    if (utf8.encode(raw).length > maximumBytes) {
      throw StateError('music_selection_quota_exceeded');
    }
    if (!await _compareAndWrite(scope, expected, raw)) return null;
    _lastWrittenKey = _storageKey(scope);
    _lastWrittenValue = raw;
    return raw;
  }

  Future<void> clear() => _clearQuietly();

  Future<void> clearIfCurrent(String value) async {
    try {
      final key = _lastWrittenValue == value ? _lastWrittenKey : null;
      if (key == null) {
        await _backend.compareAndClear(value);
      } else {
        await _compareAndClear(key, value);
      }
    } catch (_) {}
    if (_lastWrittenValue == value) {
      _lastWrittenKey = null;
      _lastWrittenValue = null;
    }
  }

  Future<void> _clearScopeIfCurrent(
    ServerMusicSelectionScope scope,
    String value,
  ) async {
    try {
      await _compareAndClear(_storageKey(scope), value);
    } catch (_) {}
  }

  Future<void> _clearQuietly() async {
    try {
      final key = _lastWrittenKey;
      if (key != null && _backend is ServerScopedStringCacheBackend) {
        await (_backend as ServerScopedStringCacheBackend).clearScoped(
          key,
          'music_selection_clear_failed',
        );
      } else {
        await _backend.clear();
      }
    } catch (_) {}
    _lastWrittenKey = null;
    _lastWrittenValue = null;
  }
}

Map<String, dynamic> _object(Object? value, Set<String> keys) {
  if (value is! Map<String, dynamic> ||
      value.length != keys.length ||
      !value.keys.every(keys.contains)) {
    throw const FormatException('invalid_music_selection');
  }
  return value;
}

String _bounded(Object? value, int maximum) {
  if (value is! String ||
      value.isEmpty ||
      value.length > maximum ||
      value.contains(RegExp(r'[\x00-\x1f\x7f]'))) {
    throw const FormatException('invalid_music_selection');
  }
  return value;
}

int _revision(Object? value) {
  if (value is! int || value < 1 || value > 0x7fffffffffffffff) {
    throw const FormatException('invalid_music_selection');
  }
  return value;
}

List<String> _strings(Object? value) {
  if (value is! List || value.length > 64) {
    throw const FormatException('invalid_music_selection');
  }
  final result = value.map((item) => _bounded(item, 128)).toList();
  if (result.toSet().length != result.length) {
    throw const FormatException('invalid_music_selection');
  }
  return result;
}

bool _sameStrings(List<String> left, List<String> right) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index++) {
    if (left[index] != right[index]) return false;
  }
  return true;
}

bool _sameProvider(
  ServerMusicProviderBinding left,
  ServerMusicProviderBinding right,
) =>
    left.setupId == right.setupId &&
    left.revision == right.revision &&
    left.domain == right.domain &&
    left.instanceId == right.instanceId;

bool _sameReceiver(ServerMusicReceiver left, ServerMusicReceiver right) =>
    left.id == right.id &&
    left.provider == right.provider &&
    left.kind == right.kind &&
    _sameStrings(left.groupMembers, right.groupMembers) &&
    left.queueId == right.queueId;
