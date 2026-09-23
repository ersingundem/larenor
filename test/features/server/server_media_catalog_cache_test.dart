import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/server/media_catalog/data/server_media_catalog_cache.dart';
import 'package:larenor/features/server/media_catalog/domain/server_media_catalog_models.dart';
import 'package:shared_preferences/shared_preferences.dart';

final class _MemoryBackend implements ServerMediaCatalogCacheBackend {
  String? value;
  int writes = 0, clears = 0;
  Completer<void>? readGate, writeGate;
  String? replacementBeforeClear;

  @override
  Future<String?> read() async {
    final captured = value;
    final gate = readGate;
    if (gate != null) await gate.future;
    return captured;
  }

  @override
  Future<bool> compareAndWrite(
    String? expected,
    String next, {
    required bool Function() current,
  }) async {
    if (!current()) return false;
    if (value != expected) return false;
    value = next;
    writes++;
    final gate = writeGate;
    if (gate != null) await gate.future;
    if (!current()) {
      await compareAndClear(next);
      return false;
    }
    return true;
  }

  @override
  Future<bool> compareAndClear(String expected) async {
    final replacement = replacementBeforeClear;
    replacementBeforeClear = null;
    if (replacement != null) value = replacement;
    if (value != expected) return false;
    value = null;
    clears++;
    return true;
  }
}

const _scope = ServerMediaCatalogCacheScope(
  coreId: '11111111111111111111111111111111',
  homeId: '22222222222222222222222222222222',
  accountId: 'operator@example.test',
);

Map<String, Object?> _pageJson({
  int installationRevision = 7,
  int snapshotRevision = 9,
  int serviceRevision = 11,
  int itemCount = 1,
  bool largeTitles = false,
}) => {
  'schemaVersion': 1,
  'installationId': '33333333333333333333333333333333',
  'installationRevision': installationRevision,
  'snapshotRevision': snapshotRevision,
  'jellyfinServiceRevision': serviceRevision,
  'offset': 0,
  'nextOffset': null,
  'total': itemCount,
  'items': [
    for (var index = 1; index <= itemCount; index++)
      {
        'itemId': index.toRadixString(16).padLeft(32, '0'),
        'mediaKey': 'movie:tmdb:$index',
        'title': largeTitles ? List.filled(120, '🎬').join() : 'Movie $index',
        'mediaKind': 'movie',
        'runtimeSeconds': 7200,
      },
  ],
};

ServerMediaCatalogPage _page({
  int installationRevision = 7,
  int snapshotRevision = 9,
  int serviceRevision = 11,
  int itemCount = 1,
  bool largeTitles = false,
}) => ServerMediaCatalogPage.fromJson(
  _pageJson(
    installationRevision: installationRevision,
    snapshotRevision: snapshotRevision,
    serviceRevision: serviceRevision,
    itemCount: itemCount,
    largeTitles: largeTitles,
  ),
  query: 'matrix',
  mediaKind: ServerMediaCatalogKind.movie,
);

ServerMediaCatalogCacheResource _resource({
  int installationRevision = 7,
  int snapshotRevision = 9,
  int serviceRevision = 11,
}) => ServerMediaCatalogCacheResource(
  installationId: '33333333333333333333333333333333',
  installationRevision: installationRevision,
  snapshotRevision: snapshotRevision,
  jellyfinServiceRevision: serviceRevision,
);

void main() {
  test('SharedPreferences backend survives a fresh cache instance', () async {
    SharedPreferences.setMockInitialValues({});
    final writer = SharedPreferencesServerMediaCatalogCacheBackend();
    expect(
      await writer.compareAndWrite(null, 'snapshot', current: () => true),
      isTrue,
    );

    final reader = SharedPreferencesServerMediaCatalogCacheBackend();
    expect(await reader.read(), 'snapshot');
    expect(await reader.compareAndClear('snapshot'), isTrue);
    expect(await writer.read(), isNull);
  });

  test(
    'SharedPreferences write clears an owner retired after persistence',
    () async {
      SharedPreferences.setMockInitialValues({});
      final backend = SharedPreferencesServerMediaCatalogCacheBackend();
      var checks = 0;

      expect(
        await backend.compareAndWrite(
          null,
          'stale snapshot',
          current: () => ++checks < 4,
        ),
        isFalse,
      );
      expect(await backend.read(), isNull);
    },
  );

  test(
    'binds exact tuple, query, kind, resource, schema, TTL and UTF-8 quota',
    () async {
      final backend = _MemoryBackend();
      var now = DateTime.utc(2026, 9, 23, 12);
      final cache = ServerMediaCatalogCache(backend: backend, now: () => now);
      final page = _page();

      expect(
        await cache.write(_scope, page, limit: 24, current: () => true),
        isTrue,
      );
      final record = jsonDecode(backend.value!) as Map<String, dynamic>;
      expect(record['schemaVersion'], 2);
      expect(backend.value, isNot(contains('accessToken')));
      expect(backend.value, isNot(contains('https://')));
      expect(
        await cache.read(
          _scope,
          _resource(),
          query: 'matrix',
          mediaKind: ServerMediaCatalogKind.movie,
          limit: 24,
          current: () => true,
        ),
        isNotNull,
      );

      for (final otherScope in const [
        ServerMediaCatalogCacheScope(
          coreId: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
          homeId: '22222222222222222222222222222222',
          accountId: 'operator@example.test',
        ),
        ServerMediaCatalogCacheScope(
          coreId: '11111111111111111111111111111111',
          homeId: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
          accountId: 'operator@example.test',
        ),
        ServerMediaCatalogCacheScope(
          coreId: '11111111111111111111111111111111',
          homeId: '22222222222222222222222222222222',
          accountId: 'other@example.test',
        ),
      ]) {
        expect(
          await cache.read(
            otherScope,
            _resource(),
            query: 'matrix',
            mediaKind: ServerMediaCatalogKind.movie,
            limit: 24,
            current: () => true,
          ),
          isNull,
        );
      }
      for (final otherResource in [
        _resource(installationRevision: 8),
        _resource(snapshotRevision: 10),
        _resource(serviceRevision: 12),
      ]) {
        expect(
          await cache.read(
            _scope,
            otherResource,
            query: 'matrix',
            mediaKind: ServerMediaCatalogKind.movie,
            limit: 24,
            current: () => true,
          ),
          isNull,
        );
      }
      expect(
        await cache.read(
          _scope,
          _resource(),
          query: 'alien',
          mediaKind: ServerMediaCatalogKind.movie,
          limit: 24,
          current: () => true,
        ),
        isNull,
      );
      expect(
        await cache.read(
          _scope,
          _resource(),
          query: 'matrix',
          mediaKind: null,
          limit: 24,
          current: () => true,
        ),
        isNull,
      );
      expect(
        await cache.read(
          _scope,
          _resource(),
          query: 'matrix',
          mediaKind: ServerMediaCatalogKind.movie,
          limit: 1,
          current: () => true,
        ),
        isNull,
      );

      now = now.add(ServerMediaCatalogCache.timeToLive);
      expect(
        await cache.read(
          _scope,
          _resource(),
          query: 'matrix',
          mediaKind: ServerMediaCatalogKind.movie,
          limit: 24,
          current: () => true,
        ),
        isNull,
      );
      expect(backend.value, isNull);

      now = DateTime.utc(2026, 9, 23, 12);
      await expectLater(
        cache.write(
          _scope,
          _page(itemCount: 50, largeTitles: true),
          limit: 50,
          current: () => true,
        ),
        throwsStateError,
      );
    },
  );

  test('browse and search cache identities never collide', () async {
    final backend = _MemoryBackend();
    final cache = ServerMediaCatalogCache(
      backend: backend,
      now: () => DateTime.utc(2026, 9, 23, 12),
    );
    final browse = ServerMediaCatalogPage.fromJson(
      _pageJson(),
      operation: ServerMediaCatalogOperation.browse,
      mediaKind: ServerMediaCatalogKind.movie,
    );

    expect(
      await cache.write(_scope, browse, limit: 24, current: () => true),
      isTrue,
    );
    expect(
      await cache.read(
        _scope,
        _resource(),
        query: 'matrix',
        mediaKind: ServerMediaCatalogKind.movie,
        limit: 24,
        current: () => true,
      ),
      isNull,
    );
    expect(
      await cache.readBrowse(
        _scope,
        _resource(),
        mediaKind: ServerMediaCatalogKind.movie,
        limit: 24,
        current: () => true,
      ),
      isNotNull,
    );
  });

  test('strict parse clears only the exact malformed owner', () async {
    final backend = _MemoryBackend();
    final cache = ServerMediaCatalogCache(
      backend: backend,
      now: () => DateTime.utc(2026, 9, 23, 12),
    );
    await cache.write(_scope, _page(), limit: 24, current: () => true);
    final valid = backend.value!;

    for (final mutate in <void Function(Map<String, dynamic>)>[
      (record) => record['schemaVersion'] = 1.0,
      (record) => record['unexpected'] = true,
      (record) =>
          (record['resource'] as Map<String, dynamic>)['snapshotRevision'] =
              1.0,
      (record) => (record['page'] as Map<String, dynamic>)['accessToken'] =
          'must-not-cross-cache-boundary',
    ]) {
      final record = jsonDecode(valid) as Map<String, dynamic>;
      mutate(record);
      backend.value = jsonEncode(record);
      final replacement = '$valid ';
      backend.replacementBeforeClear = replacement;

      expect(
        await cache.read(
          _scope,
          _resource(),
          query: 'matrix',
          mediaKind: ServerMediaCatalogKind.movie,
          limit: 24,
          current: () => true,
        ),
        isNull,
      );
      expect(backend.value, replacement);
    }
  });

  test('retirement during a delayed read publishes no cached page', () async {
    final backend = _MemoryBackend();
    final cache = ServerMediaCatalogCache(
      backend: backend,
      now: () => DateTime.utc(2026, 9, 23, 12),
    );
    await cache.write(_scope, _page(), limit: 24, current: () => true);
    backend.readGate = Completer<void>();
    var current = true;

    final read = cache.read(
      _scope,
      _resource(),
      query: 'matrix',
      mediaKind: ServerMediaCatalogKind.movie,
      limit: 24,
      current: () => current,
    );
    await Future<void>.delayed(Duration.zero);
    current = false;
    backend.readGate!.complete();

    expect(await read, isNull);
  });

  test(
    'retirement during a delayed write removes only its exact stale value',
    () async {
      for (final replacementWins in [false, true]) {
        final backend = _MemoryBackend()..writeGate = Completer<void>();
        final cache = ServerMediaCatalogCache(
          backend: backend,
          now: () => DateTime.utc(2026, 9, 23, 12),
        );
        var current = true;
        final write = cache.write(
          _scope,
          _page(),
          limit: 24,
          current: () => current,
        );
        while (backend.value == null) {
          await Future<void>.delayed(Duration.zero);
        }
        final stale = backend.value!;
        current = false;
        if (replacementWins) backend.replacementBeforeClear = '$stale ';
        backend.writeGate!.complete();

        expect(await write, isFalse);
        expect(backend.value, replacementWins ? '$stale ' : null);
      }
    },
  );
}
