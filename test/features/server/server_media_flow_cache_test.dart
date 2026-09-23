import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/server/media_flow/data/server_media_flow_cache.dart';
import 'package:larenor/features/server/media_flow/domain/server_media_flow_models.dart';
import 'package:shared_preferences/shared_preferences.dart';

final class _MemoryBackend implements ServerMediaFlowCacheBackend {
  String? value;
  int writes = 0, clears = 0;
  String? replacementBeforeMutation;

  @override
  Future<bool> compareAndClear(String expected) async {
    final replacement = replacementBeforeMutation;
    replacementBeforeMutation = null;
    if (replacement != null) value = replacement;
    if (value != expected) return false;
    clears++;
    value = null;
    return true;
  }

  @override
  Future<bool> compareAndWrite(String? expected, String value) async {
    final replacement = replacementBeforeMutation;
    replacementBeforeMutation = null;
    if (replacement != null) this.value = replacement;
    if (this.value != expected) return false;
    writes++;
    this.value = value;
    return true;
  }

  @override
  Future<void> clear() async {
    clears++;
    value = null;
  }

  @override
  Future<String?> read() async => value;

  @override
  Future<void> write(String value) async {
    writes++;
    this.value = value;
  }
}

const _scope = ServerMediaFlowCacheScope(
  coreId: '11111111111111111111111111111111',
  homeId: '22222222222222222222222222222222',
  accountId: 'operator@example.test',
);

List<Map<String, Object>> _sources({int flowRevision = 9}) => [
  for (final provider in serverMediaFlowProviderOrder)
    {
      'provider': provider,
      'serviceRevision': 7,
      'snapshotRevision': flowRevision,
      'observedAt': 1790150340,
    },
];

Map<String, Object?> _flowJson({
  String mediaKey = 'movie:tmdb:603',
  int flowRevision = 9,
}) => {
  'mediaKey': mediaKey,
  'flowRevision': flowRevision,
  'state': 'playable',
  'stages': [
    {
      'name': 'request',
      'state': 'complete',
      'provider': 'seerr',
      'sourceRevision': 7,
    },
    {
      'name': 'download',
      'state': 'complete',
      'provider': 'qbittorrent',
      'sourceRevision': 7,
    },
    {
      'name': 'import',
      'state': 'complete',
      'provider': 'radarr',
      'sourceRevision': 7,
    },
    {
      'name': 'playable',
      'state': 'complete',
      'provider': 'jellyfin',
      'sourceRevision': 7,
    },
  ],
  'sources': _sources(flowRevision: flowRevision),
  'seasons': const [],
  'delivery': const {
    'state': 'hardlink_verified',
    'retryAttempt': 1,
    'fileCount': 1,
  },
};

ServerMediaFlowStatus _flow({
  String mediaKey = 'movie:tmdb:603',
  int flowRevision = 9,
}) => ServerMediaFlowStatus.fromJson(
  _flowJson(mediaKey: mediaKey, flowRevision: flowRevision),
);

ServerMediaFlowAuthority _authority({
  String mediaKey = 'movie:tmdb:603',
  int flowRevision = 9,
}) => ServerMediaFlowAuthority.fromJson({
  'requestId': 'a' * 32,
  'mediaKey': mediaKey,
  'flowRevision': flowRevision,
  'sources': _sources(flowRevision: flowRevision),
});

ServerMediaFlowStatus _oversizedSeries() {
  final episodes = [for (var episode = 1; episode <= 1000; episode++) episode];
  final value = _flowJson(mediaKey: 'series:tvdb:81189')..['state'] = 'partial';
  value['stages'] = [
    (value['stages'] as List)[0],
    (value['stages'] as List)[1],
    {
      ...(value['stages'] as List)[2] as Map<String, Object>,
      'provider': 'sonarr',
    },
    {
      ...(value['stages'] as List)[3] as Map<String, Object>,
      'state': 'partial',
    },
  ];
  value['seasons'] = [
    for (var season = 0; season < 100; season++)
      {
        'seasonNumber': season,
        'knownEpisodes': episodes,
        'downloadedEpisodes': const <int>[],
        'importedEpisodes': const <int>[],
        'playableEpisodes': const <int>[],
        'missingEpisodes': episodes,
        'requested': true,
        'requestable': false,
        'incomplete': true,
        'missingSeason': true,
        'partialImport': false,
      },
  ];
  value['delivery'] = null;
  return ServerMediaFlowStatus.fromJson(value);
}

void main() {
  test('SharedPreferences backend survives a fresh cache backend', () async {
    SharedPreferences.setMockInitialValues({});
    final writer = SharedPreferencesServerMediaFlowCacheBackend();
    await writer.write('snapshot');

    final reader = SharedPreferencesServerMediaFlowCacheBackend();
    expect(await reader.read(), 'snapshot');

    await reader.clear();
    expect(await writer.read(), isNull);
  });

  test('binds exact tuple, flow authority, schema, TTL and quota', () async {
    final backend = _MemoryBackend();
    var now = DateTime.utc(2026, 9, 23, 8);
    final cache = ServerMediaFlowCache(backend: backend, now: () => now);
    final flow = _flow();
    final authority = _authority();

    await cache.write(_scope, flow);

    expect(await cache.read(_scope, authority), isNotNull);
    expect(jsonDecode(backend.value!)['schemaVersion'], 1);
    expect(backend.value, isNot(contains('token')));
    expect(backend.value, isNot(contains('password')));
    expect(backend.value, isNot(contains('http')));

    for (final otherScope in const [
      ServerMediaFlowCacheScope(
        coreId: '33333333333333333333333333333333',
        homeId: '22222222222222222222222222222222',
        accountId: 'operator@example.test',
      ),
      ServerMediaFlowCacheScope(
        coreId: '11111111111111111111111111111111',
        homeId: '33333333333333333333333333333333',
        accountId: 'operator@example.test',
      ),
      ServerMediaFlowCacheScope(
        coreId: '11111111111111111111111111111111',
        homeId: '22222222222222222222222222222222',
        accountId: 'other@example.test',
      ),
    ]) {
      expect(await cache.read(otherScope, authority), isNull);
    }
    expect(
      await cache.read(_scope, _authority(mediaKey: 'movie:tmdb:604')),
      isNull,
    );
    expect(await cache.read(_scope, _authority(flowRevision: 10)), isNull);

    now = now.add(ServerMediaFlowCache.timeToLive);
    expect(await cache.read(_scope, authority), isNull);

    await cache.write(_scope, flow);
    final wrongSchema = jsonDecode(backend.value!) as Map<String, dynamic>;
    wrongSchema['schemaVersion'] = 2;
    backend.value = jsonEncode(wrongSchema);
    expect(await cache.read(_scope, authority), isNull);
    expect(backend.value, isNull);

    backend.value = 'x' * (ServerMediaFlowCache.maximumBytes + 1);
    expect(await cache.read(_scope, authority), isNull);
    expect(backend.value, isNull);

    final writes = backend.writes;
    await expectLater(
      cache.write(_scope, _oversizedSeries()),
      throwsStateError,
    );
    expect(backend.writes, writes);
  });

  test('unknown or contradictory stored flow data is cleared', () async {
    final backend = _MemoryBackend();
    final cache = ServerMediaFlowCache(
      backend: backend,
      now: () => DateTime.utc(2026, 9, 23, 8),
    );
    final flow = _flow();
    final authority = _authority();
    await cache.write(_scope, flow);
    final raw = jsonDecode(backend.value!) as Map<String, dynamic>;
    final storedFlow = raw['flow'] as Map<String, dynamic>;
    storedFlow['accessToken'] = 'must-not-cross-cache-boundary';
    backend.value = jsonEncode(raw);

    expect(await cache.read(_scope, authority), isNull);
    expect(backend.value, isNull);

    await cache.write(_scope, flow);
    final resourceRaw = jsonDecode(backend.value!) as Map<String, dynamic>;
    final resource = resourceRaw['resource'] as Map<String, dynamic>;
    final sources = resource['sources'] as List<dynamic>;
    sources[0] = {
      ...(sources[0] as Map<String, dynamic>),
      'accessToken': 'must-not-cross-cache-boundary',
    };
    backend.value = jsonEncode(resourceRaw);

    expect(await cache.read(_scope, authority), isNull);
    expect(backend.value, isNull);
  });

  test(
    'malformed expired and oversized cleanup preserves a replacement owner',
    () async {
      for (final invalid in ['malformed', 'expired', 'oversized']) {
        final backend = _MemoryBackend();
        var now = DateTime.utc(2026, 9, 23, 8);
        final cache = ServerMediaFlowCache(backend: backend, now: () => now);
        await cache.write(_scope, _flow());
        final valid = backend.value!;
        final replacement = '$valid ';

        switch (invalid) {
          case 'malformed':
            final record = jsonDecode(valid) as Map<String, dynamic>;
            record['unexpected'] = true;
            backend.value = jsonEncode(record);
          case 'expired':
            backend.value = valid;
            now = now.add(ServerMediaFlowCache.timeToLive);
          case 'oversized':
            backend.value = 'x' * (ServerMediaFlowCache.maximumBytes + 1);
        }
        backend.replacementBeforeMutation = replacement;

        expect(await cache.read(_scope, _authority()), isNull, reason: invalid);
        expect(backend.value, replacement, reason: invalid);
      }
    },
  );

  test('a stale writer cannot replace a newer exact flow record', () async {
    final backend = _MemoryBackend();
    final cache = ServerMediaFlowCache(
      backend: backend,
      now: () => DateTime.utc(2026, 9, 23, 8),
    );
    expect(await cache.write(_scope, _flow()), isTrue);
    final stale = backend.value!;
    expect(await cache.write(_scope, _flow(flowRevision: 10)), isTrue);
    final replacement = backend.value!;
    backend.value = stale;
    backend.replacementBeforeMutation = replacement;

    expect(await cache.write(_scope, _flow()), isFalse);

    expect(backend.value, replacement);
    expect(await cache.read(_scope, _authority(flowRevision: 10)), isNotNull);
  });

  test('schema version requires exact integer one', () async {
    final backend = _MemoryBackend();
    final cache = ServerMediaFlowCache(
      backend: backend,
      now: () => DateTime.utc(2026, 9, 23, 8),
    );
    await cache.write(_scope, _flow());
    final record = jsonDecode(backend.value!) as Map<String, dynamic>;
    record['schemaVersion'] = 1.0;
    backend.value = jsonEncode(record);

    expect(await cache.read(_scope, _authority()), isNull);
    expect(backend.value, isNull);
  });
}
