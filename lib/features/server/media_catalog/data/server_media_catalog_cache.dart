import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../../../../core/configuration_writes.dart';
import '../../domain/server_models.dart';
import '../domain/server_media_catalog_models.dart';

abstract interface class ServerMediaCatalogCacheBackend {
  Future<String?> read();
  Future<bool> compareAndWrite(
    String? expected,
    String value, {
    required bool Function() current,
  });
  Future<bool> compareAndClear(String expected);
}

final class SharedPreferencesServerMediaCatalogCacheBackend
    implements ServerMediaCatalogCacheBackend {
  SharedPreferencesServerMediaCatalogCacheBackend({
    Future<SharedPreferences> Function()? loadPreferences,
  }) : _loadPreferences = loadPreferences ?? SharedPreferences.getInstance;

  static const key = 'server_media_catalog_cache_v2';
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
      throw StateError('media_catalog_cache_write_failed');
    }
    if (!isCurrent()) {
      await preferences.reload();
      if (preferences.getString(key) == value &&
          !await preferences.remove(key)) {
        throw StateError('media_catalog_cache_clear_failed');
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
          throw StateError('media_catalog_cache_clear_failed');
        }
        return true;
      });
}

final class ServerMediaCatalogCacheScope {
  const ServerMediaCatalogCacheScope({
    required this.coreId,
    required this.homeId,
    required this.accountId,
  });

  factory ServerMediaCatalogCacheScope.fromSession(ServerSession session) {
    final context = session.context;
    if (context == null) {
      throw StateError('media_catalog_cache_scope_unavailable');
    }
    return ServerMediaCatalogCacheScope(
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
  String toString() => 'ServerMediaCatalogCacheScope(redacted)';
}

final class ServerMediaCatalogCacheResource {
  const ServerMediaCatalogCacheResource({
    required this.installationId,
    required this.installationRevision,
    required this.snapshotRevision,
    required this.jellyfinServiceRevision,
  });

  factory ServerMediaCatalogCacheResource.fromPage(
    ServerMediaCatalogPage page,
  ) => ServerMediaCatalogCacheResource(
    installationId: page.installationId,
    installationRevision: page.installationRevision,
    snapshotRevision: page.snapshotRevision,
    jellyfinServiceRevision: page.jellyfinServiceRevision,
  );

  final String installationId;
  final int installationRevision, snapshotRevision, jellyfinServiceRevision;

  bool get valid =>
      RegExp(r'^[a-f0-9]{32}$').hasMatch(installationId) &&
      _validRevision(installationRevision) &&
      _validRevision(snapshotRevision) &&
      _validRevision(jellyfinServiceRevision);

  Map<String, Object> toJson() => {
    'kind': 'media_catalog',
    'installationId': installationId,
    'installationRevision': installationRevision,
    'snapshotRevision': snapshotRevision,
    'jellyfinServiceRevision': jellyfinServiceRevision,
  };

  bool matches(ServerMediaCatalogCacheResource other) =>
      installationId == other.installationId &&
      installationRevision == other.installationRevision &&
      snapshotRevision == other.snapshotRevision &&
      jellyfinServiceRevision == other.jellyfinServiceRevision;

  @override
  String toString() => 'ServerMediaCatalogCacheResource(redacted)';
}

final class ServerMediaCatalogCache {
  ServerMediaCatalogCache({
    ServerMediaCatalogCacheBackend? backend,
    DateTime Function()? now,
  }) : _backend = backend ?? SharedPreferencesServerMediaCatalogCacheBackend(),
       _now = now ?? DateTime.now;

  static const maximumBytes = 16 * 1024;
  static const timeToLive = Duration(minutes: 10);

  final ServerMediaCatalogCacheBackend _backend;
  final DateTime Function() _now;

  Future<ServerMediaCatalogPage?> read(
    ServerMediaCatalogCacheScope scope,
    ServerMediaCatalogCacheResource resource, {
    required String query,
    required ServerMediaCatalogKind? mediaKind,
    required int limit,
    required bool Function() current,
  }) => _read(
    scope,
    resource,
    operation: ServerMediaCatalogOperation.search,
    query: query,
    mediaKind: mediaKind,
    limit: limit,
    current: current,
  );

  Future<ServerMediaCatalogPage?> readBrowse(
    ServerMediaCatalogCacheScope scope,
    ServerMediaCatalogCacheResource resource, {
    required ServerMediaCatalogKind? mediaKind,
    required int limit,
    required bool Function() current,
  }) => _read(
    scope,
    resource,
    operation: ServerMediaCatalogOperation.browse,
    query: null,
    mediaKind: mediaKind,
    limit: limit,
    current: current,
  );

  Future<ServerMediaCatalogPage?> _read(
    ServerMediaCatalogCacheScope scope,
    ServerMediaCatalogCacheResource resource, {
    required ServerMediaCatalogOperation operation,
    required String? query,
    required ServerMediaCatalogKind? mediaKind,
    required int limit,
    required bool Function() current,
  }) async {
    bool isCurrent() {
      try {
        return current();
      } catch (_) {
        return false;
      }
    }

    if (!isCurrent() ||
        !scope.valid ||
        !resource.valid ||
        !_validRequest(operation, query) ||
        !_validLimit(limit)) {
      return null;
    }
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
        'request',
        'page',
      });
      if (record['schemaVersion'] is! int || record['schemaVersion'] != 2) {
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
      final request = _object(record['request'], {
        'operation',
        'query',
        'mediaKind',
        'limit',
      });
      final storedQuery = request['query'];
      final storedLimit = request['limit'];
      final storedOperation = switch (request['operation']) {
        'browse' => ServerMediaCatalogOperation.browse,
        'search' => ServerMediaCatalogOperation.search,
        _ => throw const FormatException(),
      };
      final storedKind = switch (request['mediaKind']) {
        null => null,
        'movie' => ServerMediaCatalogKind.movie,
        'episode' => ServerMediaCatalogKind.episode,
        _ => throw const FormatException(),
      };
      if (storedQuery != null && storedQuery is! String ||
          !_validRequest(storedOperation, storedQuery as String?) ||
          storedOperation != operation ||
          storedQuery != query ||
          storedKind != mediaKind ||
          storedLimit is! int ||
          !_validLimit(storedLimit) ||
          storedLimit != limit) {
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
      final page = ServerMediaCatalogPage.fromJson(
        record['page'],
        operation: storedOperation,
        query: storedQuery,
        mediaKind: storedKind,
      );
      if (page.offset != 0 ||
          !ServerMediaCatalogCacheResource.fromPage(page).matches(resource)) {
        throw const FormatException();
      }
      if (!isCurrent()) return null;
      return page;
    } catch (_) {
      await _clearIfCurrent(raw, isCurrent);
      return null;
    }
  }

  Future<bool> write(
    ServerMediaCatalogCacheScope scope,
    ServerMediaCatalogPage page, {
    required int limit,
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
    final resource = ServerMediaCatalogCacheResource.fromPage(page);
    if (!scope.valid ||
        !resource.valid ||
        page.offset != 0 ||
        !_validLimit(limit) ||
        page.items.length > limit ||
        !_validRequest(page.operation, page.query)) {
      throw StateError('media_catalog_cache_value_invalid');
    }
    final savedAt = _now().toUtc();
    final expected = await _backend.read();
    if (!isCurrent()) return false;
    final raw = jsonEncode({
      'schemaVersion': 2,
      'scope': scope.toJson(),
      'resource': resource.toJson(),
      'savedAt': savedAt.toIso8601String(),
      'request': {
        'operation': page.operation.name,
        'query': page.query,
        'mediaKind': page.mediaKind?.wire,
        'limit': limit,
      },
      'page': _pageJson(page),
    });
    if (raw.length > maximumBytes || utf8.encode(raw).length > maximumBytes) {
      throw StateError('media_catalog_cache_quota_exceeded');
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

ServerMediaCatalogCacheResource _resource(Object? value) {
  final resource = _object(value, {
    'kind',
    'installationId',
    'installationRevision',
    'snapshotRevision',
    'jellyfinServiceRevision',
  });
  if (resource['kind'] != 'media_catalog' ||
      resource['installationId'] is! String ||
      resource['installationRevision'] is! int ||
      resource['snapshotRevision'] is! int ||
      resource['jellyfinServiceRevision'] is! int) {
    throw const FormatException();
  }
  final parsed = ServerMediaCatalogCacheResource(
    installationId: resource['installationId'] as String,
    installationRevision: resource['installationRevision'] as int,
    snapshotRevision: resource['snapshotRevision'] as int,
    jellyfinServiceRevision: resource['jellyfinServiceRevision'] as int,
  );
  if (!parsed.valid) throw const FormatException();
  return parsed;
}

Map<String, Object?> _pageJson(ServerMediaCatalogPage page) => {
  'schemaVersion': 1,
  'installationId': page.installationId,
  'installationRevision': page.installationRevision,
  'snapshotRevision': page.snapshotRevision,
  'jellyfinServiceRevision': page.jellyfinServiceRevision,
  'offset': page.offset,
  'nextOffset': page.nextOffset,
  'total': page.total,
  'items': [
    for (final item in page.items)
      {
        'itemId': item.itemId,
        'mediaKey': item.mediaKey,
        'title': item.title,
        'mediaKind': item.kind.wire,
        'runtimeSeconds': item.runtimeSeconds,
      },
  ],
};

Map<String, dynamic> _object(Object? value, Set<String> keys) {
  if (value is! Map<String, dynamic> ||
      value.length != keys.length ||
      !value.keys.every(keys.contains)) {
    throw const FormatException('invalid_media_catalog_cache');
  }
  return value;
}

bool _validRevision(int value) => value >= 1 && value <= 0x7ffffffffffffffe;

bool _validQuery(String value) =>
    value.isNotEmpty &&
    value.length <= 80 &&
    value == value.trim() &&
    !RegExp(
      r'[\u0000-\u001f\u007f-\u009f\u200e\u200f\u202a-\u202e\u2066-\u2069\ufeff]',
    ).hasMatch(value);

bool _validRequest(ServerMediaCatalogOperation operation, String? query) =>
    operation == ServerMediaCatalogOperation.browse
    ? query == null
    : query != null && _validQuery(query);

bool _validLimit(int value) => value >= 1 && value <= 50;
