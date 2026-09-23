import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../../../../core/configuration_writes.dart';
import '../../domain/server_models.dart';
import '../domain/server_music_manager_models.dart';

abstract interface class ServerMusicCommandReceiptCacheBackend {
  Future<String?> read();
  Future<bool> compareAndWrite(
    String? expected,
    String value, {
    required bool Function() current,
  });
  Future<bool> compareAndClear(String expected);
}

final class SharedPreferencesServerMusicCommandReceiptCacheBackend
    implements ServerMusicCommandReceiptCacheBackend {
  SharedPreferencesServerMusicCommandReceiptCacheBackend({
    Future<SharedPreferences> Function()? loadPreferences,
  }) : _loadPreferences = loadPreferences ?? SharedPreferences.getInstance;

  static const key = 'server_music_command_receipt_cache_v1';
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
      throw StateError('music_receipt_cache_write_failed');
    }
    if (!isCurrent()) {
      await preferences.reload();
      if (preferences.getString(key) == value &&
          !await preferences.remove(key)) {
        throw StateError('music_receipt_cache_clear_failed');
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
          throw StateError('music_receipt_cache_clear_failed');
        }
        return true;
      });
}

final class ServerMusicCommandReceiptScope {
  const ServerMusicCommandReceiptScope({
    required this.coreId,
    required this.homeId,
    required this.accountId,
  });

  factory ServerMusicCommandReceiptScope.fromSession(ServerSession session) {
    final context = session.context;
    if (context == null) throw StateError('music_receipt_scope_unavailable');
    return ServerMusicCommandReceiptScope(
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
  String toString() => 'ServerMusicCommandReceiptScope(redacted)';
}

final class ServerMusicCommandReceiptCache {
  ServerMusicCommandReceiptCache({
    ServerMusicCommandReceiptCacheBackend? backend,
    DateTime Function()? now,
  }) : _backend =
           backend ?? SharedPreferencesServerMusicCommandReceiptCacheBackend(),
       _now = now ?? DateTime.now;

  static const maximumBytes = 8 * 1024;
  static const timeToLive = Duration(minutes: 2);

  final ServerMusicCommandReceiptCacheBackend _backend;
  final DateTime Function() _now;

  Future<ServerMusicReceipt?> read(
    ServerMusicCommandReceiptScope scope,
    ServerMusicManager manager, {
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
        'receipt',
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
        'targetId',
        'provider',
        'targetKind',
        'groupMembers',
        'queueId',
      });
      _validateResource(resource);
      if (!_resourceMatches(resource, manager)) return null;
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
      final receipt = ServerMusicReceipt.fromJson(record['receipt']);
      if (!receipt.authenticated ||
          receipt.playerRevision != manager.revision ||
          receipt.targetId != resource['targetId']) {
        throw const FormatException();
      }
      if (!isCurrent()) return null;
      return receipt;
    } catch (_) {
      await _clearIfCurrent(raw, isCurrent);
      return null;
    }
  }

  Future<bool> write(
    ServerMusicCommandReceiptScope scope,
    ServerMusicManager manager,
    ServerMusicReceipt receipt, {
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
    final receiver = manager.receivers
        .where((candidate) => candidate.id == receipt.targetId)
        .firstOrNull;
    if (!scope.valid ||
        receiver == null ||
        !receipt.authenticated ||
        receipt.playerRevision != manager.revision) {
      throw StateError('music_receipt_cache_value_invalid');
    }
    final expected = await _backend.read();
    if (!isCurrent()) return false;
    final raw = jsonEncode({
      'schemaVersion': 1,
      'scope': scope.toJson(),
      'resource': {
        'kind': 'music_command_receipt',
        'installationId': manager.installationId,
        'installationRevision': manager.installationRevision,
        'coreRevision': manager.coreRevision,
        'managerRevision': manager.revision,
        'targetId': receiver.id,
        'provider': receiver.provider,
        'targetKind': receiver.kind,
        'groupMembers': receiver.groupMembers,
        'queueId': receiver.queueId,
      },
      'savedAt': _now().toUtc().toIso8601String(),
      'receipt': {
        'requestId': receipt.requestId,
        'targetId': receipt.targetId,
        'operation': receipt.operation,
        'state': receipt.state,
        'playerRevision': receipt.playerRevision,
        'code': receipt.code,
        'installAvailable': false,
      },
    });
    if (raw.length > maximumBytes || utf8.encode(raw).length > maximumBytes) {
      throw StateError('music_receipt_cache_quota_exceeded');
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

void _validateResource(Map<String, dynamic> resource) {
  final installationRevision = resource['installationRevision'];
  final coreRevision = resource['coreRevision'];
  final managerRevision = resource['managerRevision'];
  final members = resource['groupMembers'];
  if (resource['kind'] != 'music_command_receipt' ||
      resource['installationId'] is! String ||
      !RegExp(r'^[a-f0-9]{32}$')
          .hasMatch(resource['installationId'] as String) ||
      installationRevision is! int ||
      installationRevision < 1 ||
      installationRevision > 0x7fffffffffffffff ||
      coreRevision is! int ||
      coreRevision < 1 ||
      coreRevision > 0x7fffffffffffffff ||
      managerRevision is! int ||
      managerRevision < 1 ||
      managerRevision > 0x7fffffffffffffff ||
      !_isBinding(resource['targetId']) ||
      !_isBinding(resource['provider']) ||
      !const {
        'homepod',
        'airplay',
        'airplay_group',
        'cast',
        'cast_group',
        'group',
        'other',
      }.contains(resource['targetKind']) ||
      resource['queueId'] != null && !_isBinding(resource['queueId']) ||
      members is! List ||
      members.length > 64 ||
      members.any((value) => !_isBinding(value)) ||
      members.toSet().length != members.length) {
    throw const FormatException('invalid_music_receipt_resource');
  }
}

bool _isBinding(Object? value) =>
    value is String &&
    RegExp(r'^[A-Za-z0-9][A-Za-z0-9_.:\-]{0,127}$').hasMatch(value);

bool _resourceMatches(
  Map<String, dynamic> resource,
  ServerMusicManager manager,
) {
  if (resource['kind'] != 'music_command_receipt' ||
      resource['installationId'] != manager.installationId ||
      resource['installationRevision'] is! int ||
      resource['installationRevision'] != manager.installationRevision ||
      resource['coreRevision'] is! int ||
      resource['coreRevision'] != manager.coreRevision ||
      resource['managerRevision'] is! int ||
      resource['managerRevision'] != manager.revision ||
      resource['targetId'] is! String ||
      resource['provider'] is! String ||
      resource['targetKind'] is! String ||
      resource['queueId'] != null && resource['queueId'] is! String ||
      resource['groupMembers'] is! List ||
      (resource['groupMembers'] as List).any((value) => value is! String)) {
    return false;
  }
  final target = manager.receivers
      .where((candidate) => candidate.id == resource['targetId'])
      .firstOrNull;
  if (target == null ||
      target.provider != resource['provider'] ||
      target.kind != resource['targetKind'] ||
      target.queueId != resource['queueId']) {
    return false;
  }
  final members = (resource['groupMembers'] as List).cast<String>();
  if (members.length != target.groupMembers.length) return false;
  for (var index = 0; index < members.length; index++) {
    if (members[index] != target.groupMembers[index]) return false;
  }
  return true;
}

Map<String, dynamic> _object(Object? value, Set<String> keys) {
  if (value is! Map<String, dynamic> ||
      value.length != keys.length ||
      !value.keys.every(keys.contains)) {
    throw const FormatException('invalid_music_receipt_cache');
  }
  return value;
}
