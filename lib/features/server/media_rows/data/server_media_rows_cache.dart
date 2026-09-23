import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../../../../core/configuration_writes.dart';
import '../../domain/server_models.dart';
import '../domain/server_media_rows_models.dart';

abstract interface class ServerMediaRowsCacheBackend {
  Future<String?> read();
  Future<bool> compareAndWrite(
    String? expected,
    String value, {
    required bool Function() current,
  });
  Future<bool> compareAndClear(String expected);
}

final class SharedPreferencesServerMediaRowsCacheBackend
    implements ServerMediaRowsCacheBackend {
  SharedPreferencesServerMediaRowsCacheBackend({
    Future<SharedPreferences> Function()? loadPreferences,
  }) : _loadPreferences = loadPreferences ?? SharedPreferences.getInstance;

  static const key = 'server_media_rows_cache_v1';
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
      throw StateError('media_rows_cache_write_failed');
    }
    if (!isCurrent()) {
      await preferences.reload();
      if (preferences.getString(key) == value &&
          !await preferences.remove(key)) {
        throw StateError('media_rows_cache_clear_failed');
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
          throw StateError('media_rows_cache_clear_failed');
        }
        return true;
      });
}

final class ServerMediaRowsCacheScope {
  const ServerMediaRowsCacheScope({
    required this.coreId,
    required this.homeId,
    required this.accountId,
  });

  factory ServerMediaRowsCacheScope.fromSession(ServerSession session) {
    final context = session.context;
    if (context == null) {
      throw StateError('media_rows_cache_scope_unavailable');
    }
    return ServerMediaRowsCacheScope(
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
  String toString() => 'ServerMediaRowsCacheScope(redacted)';
}

final class _ServerMediaRowsCacheResource {
  const _ServerMediaRowsCacheResource({
    required this.installationId,
    required this.installationRevision,
    required this.bindingRevision,
  });

  factory _ServerMediaRowsCacheResource.fromTarget(
    ServerMediaRowsTarget target,
  ) => _ServerMediaRowsCacheResource(
    installationId: target.installationId,
    installationRevision: target.installationRevision,
    bindingRevision: target.bindingRevision,
  );

  final String installationId;
  final int installationRevision, bindingRevision;

  bool get valid =>
      RegExp(r'^[a-f0-9]{32}$').hasMatch(installationId) &&
      _validRevision(installationRevision) &&
      _validRevision(bindingRevision);

  Map<String, Object> toJson() => {
    'kind': 'media_rows',
    'installationId': installationId,
    'installationRevision': installationRevision,
    'bindingRevision': bindingRevision,
  };

  bool matches(_ServerMediaRowsCacheResource other) =>
      installationId == other.installationId &&
      installationRevision == other.installationRevision &&
      bindingRevision == other.bindingRevision;
}

final class ServerMediaRowsCache {
  ServerMediaRowsCache({
    ServerMediaRowsCacheBackend? backend,
    DateTime Function()? now,
  }) : _backend = backend ?? SharedPreferencesServerMediaRowsCacheBackend(),
       _now = now ?? DateTime.now;

  static const maximumBytes = 96 * 1024;
  static const timeToLive = Duration(minutes: 5);

  final ServerMediaRowsCacheBackend _backend;
  final DateTime Function() _now;

  Future<ServerAccountMediaRows?> read(
    ServerMediaRowsCacheScope scope,
    ServerMediaRowsTarget target, {
    required bool Function() current,
  }) async {
    bool isCurrent() {
      try {
        return current();
      } catch (_) {
        return false;
      }
    }

    final resource = _ServerMediaRowsCacheResource.fromTarget(target);
    if (!isCurrent() || !scope.valid || !resource.valid) return null;
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
        'rows',
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
      final storedResource = _resource(record['resource']);
      if (!storedResource.matches(resource)) return null;
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
      final rows = ServerMediaRows.fromJson(record['rows']);
      if (!isCurrent()) return null;
      return ServerAccountMediaRows.cached(
        installationId: resource.installationId,
        installationRevision: resource.installationRevision,
        bindingRevision: resource.bindingRevision,
        rows: rows,
      );
    } catch (_) {
      await _clearIfCurrent(raw, isCurrent);
      return null;
    }
  }

  Future<bool> write(
    ServerMediaRowsCacheScope scope,
    ServerMediaRowsTarget target,
    ServerAccountMediaRows value, {
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
    final resource = _ServerMediaRowsCacheResource.fromTarget(target);
    if (!scope.valid ||
        !resource.valid ||
        value.installationId != resource.installationId ||
        value.installationRevision != resource.installationRevision ||
        value.bindingRevision != resource.bindingRevision) {
      throw StateError('media_rows_cache_value_invalid');
    }
    final savedAt = _now().toUtc();
    final expected = await _backend.read();
    if (!isCurrent()) return false;
    final raw = jsonEncode({
      'schemaVersion': 1,
      'scope': scope.toJson(),
      'resource': resource.toJson(),
      'savedAt': savedAt.toIso8601String(),
      'rows': _rowsJson(value.rows),
    });
    if (raw.length > maximumBytes || utf8.encode(raw).length > maximumBytes) {
      throw StateError('media_rows_cache_quota_exceeded');
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

_ServerMediaRowsCacheResource _resource(Object? value) {
  final resource = _object(value, {
    'kind',
    'installationId',
    'installationRevision',
    'bindingRevision',
  });
  if (resource['kind'] != 'media_rows' ||
      resource['installationId'] is! String ||
      resource['installationRevision'] is! int ||
      resource['bindingRevision'] is! int) {
    throw const FormatException();
  }
  final parsed = _ServerMediaRowsCacheResource(
    installationId: resource['installationId'] as String,
    installationRevision: resource['installationRevision'] as int,
    bindingRevision: resource['bindingRevision'] as int,
  );
  if (!parsed.valid) throw const FormatException();
  return parsed;
}

Map<String, Object?> _rowsJson(ServerMediaRows rows) => {
  'schemaVersion': 1,
  'revision': rows.revision,
  'recent': [for (final item in rows.recent) _itemJson(item)],
  'resume': [for (final item in rows.resume) _itemJson(item)],
};

Map<String, Object> _itemJson(ServerMediaRowItem item) => {
  'itemId': item.itemId,
  'title': item.title,
  'mediaKind': item.kind.name,
  'addedAt': item.addedAt.millisecondsSinceEpoch ~/ 1000,
  'runtimeSeconds': item.runtimeSeconds,
  'positionSeconds': item.positionSeconds,
};

Map<String, dynamic> _object(Object? value, Set<String> keys) {
  if (value is! Map<String, dynamic> ||
      value.length != keys.length ||
      !value.keys.every(keys.contains)) {
    throw const FormatException();
  }
  return value;
}

bool _validRevision(int value) => value >= 1 && value <= 0x7ffffffffffffffe;
