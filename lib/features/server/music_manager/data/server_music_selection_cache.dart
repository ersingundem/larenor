import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../../../../core/configuration_writes.dart';
import '../../domain/server_models.dart';
import '../domain/server_music_manager_models.dart';

abstract interface class ServerMusicSelectionCacheBackend {
  Future<String?> read();
  Future<bool> compareAndWrite(String? expected, String value);
  Future<bool> compareAndClear(String expected);
  Future<void> clear();
}

final class SharedPreferencesServerMusicSelectionCacheBackend
    implements ServerMusicSelectionCacheBackend {
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

  Future<ServerMusicSelection?> read(
    ServerMusicSelectionScope scope,
    ServerMusicManager manager,
  ) async {
    if (!scope.valid) return null;
    final String? raw;
    try {
      raw = await _backend.read();
    } catch (_) {
      return null;
    }
    if (raw == null) return null;
    if (utf8.encode(raw).length > maximumBytes) {
      await clearIfCurrent(raw);
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
      await clearIfCurrent(raw);
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
    final expected = await _backend.read();
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
    return await _backend.compareAndWrite(expected, raw) ? raw : null;
  }

  Future<void> clear() => _clearQuietly();

  Future<void> clearIfCurrent(String value) async {
    try {
      await _backend.compareAndClear(value);
    } catch (_) {}
  }

  Future<void> _clearQuietly() async {
    try {
      await _backend.clear();
    } catch (_) {}
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
