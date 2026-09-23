import '../../domain/server_models.dart';
import '../../media_catalog/data/server_media_catalog_api.dart';
import '../domain/server_media_rows_models.dart';

final class ServerMediaRowsCacheScope {
  const ServerMediaRowsCacheScope({
    required this.coreId,
    required this.homeId,
    required this.accountId,
  });

  factory ServerMediaRowsCacheScope.fromSession(ServerSession session) {
    final context = session.context;
    if (context == null) throw StateError('media_rows_cache_scope_unavailable');
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

  @override
  bool operator ==(Object other) =>
      other is ServerMediaRowsCacheScope &&
      coreId == other.coreId &&
      homeId == other.homeId &&
      accountId == other.accountId;

  @override
  int get hashCode => Object.hash(coreId, homeId, accountId);

  @override
  String toString() => 'ServerMediaRowsCacheScope(redacted)';
}

final class _CacheKey {
  const _CacheKey(this.scope, this.installationId, this.installationRevision);

  final ServerMediaRowsCacheScope scope;
  final String installationId;
  final int installationRevision;

  @override
  bool operator ==(Object other) =>
      other is _CacheKey &&
      scope == other.scope &&
      installationId == other.installationId &&
      installationRevision == other.installationRevision;

  @override
  int get hashCode => Object.hash(scope, installationId, installationRevision);
}

final class _CacheEntry {
  const _CacheEntry(this.value, this.savedAt);
  final ServerAccountMediaRows value;
  final DateTime savedAt;
}

/// A bounded, process-local stale-while-revalidate cache.
///
/// Rows never grant command authority. A controller always performs a fresh
/// Core read after showing a cache hit, and evicts the owning scope on account
/// retirement or home reparenting.
final class ServerMediaRowsCache {
  ServerMediaRowsCache({DateTime Function()? now}) : _now = now ?? DateTime.now;

  static final shared = ServerMediaRowsCache();
  static const timeToLive = Duration(minutes: 5);
  static const maximumEntries = 8;

  final DateTime Function() _now;
  final Map<_CacheKey, _CacheEntry> _entries = {};

  ServerAccountMediaRows? read(
    ServerMediaRowsCacheScope scope,
    ServerMediaCatalogTarget target, {
    required bool Function() current,
  }) {
    if (!_current(current) || !scope.valid) return null;
    final key = _CacheKey(
      scope,
      target.installationId,
      target.installationRevision,
    );
    final entry = _entries[key];
    if (entry == null) return null;
    final now = _now().toUtc();
    if (now.isBefore(entry.savedAt) ||
        !now.isBefore(entry.savedAt.add(timeToLive))) {
      _entries.remove(key);
      return null;
    }
    return _current(current) ? entry.value : null;
  }

  bool write(
    ServerMediaRowsCacheScope scope,
    ServerMediaCatalogTarget target,
    ServerAccountMediaRows value, {
    required bool Function() current,
  }) {
    if (!_current(current) ||
        !scope.valid ||
        value.installationId != target.installationId ||
        value.installationRevision != target.installationRevision) {
      return false;
    }
    final key = _CacheKey(
      scope,
      target.installationId,
      target.installationRevision,
    );
    _entries.remove(key);
    _entries[key] = _CacheEntry(value, _now().toUtc());
    while (_entries.length > maximumEntries) {
      _entries.remove(_entries.keys.first);
    }
    if (_current(current)) return true;
    _entries.remove(key);
    return false;
  }

  void evictScope(ServerMediaRowsCacheScope scope) {
    _entries.removeWhere((key, _) => key.scope == scope);
  }

  static bool _current(bool Function() current) {
    try {
      return current();
    } catch (_) {
      return false;
    }
  }
}
