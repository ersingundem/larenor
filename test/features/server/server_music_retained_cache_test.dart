import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/server/music_retained/data/server_music_retained_cache.dart';
import 'package:larenor/features/server/music_retained/domain/server_music_retained_models.dart';

import 'server_music_retained_status_test.dart' show retainedJson;

const scope = ServerMusicRetainedCacheScope(
  coreId: '11111111111111111111111111111111',
  homeId: '22222222222222222222222222222222',
  accountId: 'operator@example.test',
);

final class MemoryMusicRetainedCacheBackend
    implements ServerMusicRetainedCacheBackend {
  String? value;
  int writes = 0, clears = 0;
  Completer<void>? readGate;
  Completer<void>? writeGate;

  @override
  Future<String?> read() async {
    await readGate?.future;
    return value;
  }

  @override
  Future<bool> compareAndWrite(
    String? expected,
    String next, {
    required bool Function() current,
  }) async {
    await writeGate?.future;
    if (!current() || value != expected) return false;
    value = next;
    writes++;
    if (!current()) {
      if (value == next) value = null;
      return false;
    }
    return true;
  }

  @override
  Future<bool> compareAndClear(String expected) async {
    if (value != expected) return false;
    value = null;
    clears++;
    return true;
  }
}

void main() {
  test('cache binds exact home tuple, schema, TTL and quota', () async {
    final backend = MemoryMusicRetainedCacheBackend();
    var now = DateTime.utc(2026, 9, 23, 8);
    final cache = ServerMusicRetainedCache(backend: backend, now: () => now);
    final overview = ServerMusicRetainedOverview.fromJson(retainedJson());

    expect(await cache.write(scope, overview, current: () => true), isTrue);
    expect(await cache.read(scope, current: () => true), isNotNull);
    final record = jsonDecode(backend.value!) as Map<String, dynamic>;
    expect(record['schemaVersion'], 1);
    expect(record['recordId'], matches(RegExp(r'^[a-f0-9]{32}$')));
    expect(record['resource'], {
      'kind': 'music_retained_overview',
      'contractVersion': 1,
      'installations': [
        {
          'installationId': 'a' * 32,
          'installationRevision': 4,
          'bootstrap': {
            'revision': 2,
            'schemaVersion': 27,
            'homeAssistant': {'serviceId': 'b' * 32, 'serviceRevision': 8},
            'jellyfin': {'serviceId': 'c' * 32, 'serviceRevision': 5},
          },
          'providers': [
            {'id': 'd' * 32, 'revision': 3},
          ],
        },
      ],
    });
    expect(backend.value, isNot(contains('token')));
    expect(backend.value, isNot(contains('password')));
    final firstRaw = backend.value!;
    expect(await cache.write(scope, overview, current: () => true), isTrue);
    expect(backend.value, isNot(firstRaw));
    expect(await backend.compareAndClear(firstRaw), isFalse);
    expect(backend.value, isNotNull);

    for (final otherScope in const [
      ServerMusicRetainedCacheScope(
        coreId: '33333333333333333333333333333333',
        homeId: '22222222222222222222222222222222',
        accountId: 'operator@example.test',
      ),
      ServerMusicRetainedCacheScope(
        coreId: '11111111111111111111111111111111',
        homeId: '33333333333333333333333333333333',
        accountId: 'operator@example.test',
      ),
      ServerMusicRetainedCacheScope(
        coreId: '11111111111111111111111111111111',
        homeId: '22222222222222222222222222222222',
        accountId: 'other@example.test',
      ),
    ]) {
      expect(await cache.read(otherScope, current: () => true), isNull);
    }

    now = now.add(ServerMusicRetainedCache.timeToLive);
    expect(await cache.read(scope, current: () => true), isNull);
    expect(backend.value, isNull);

    backend.value = 'x' * (ServerMusicRetainedCache.maximumBytes + 1);
    expect(await cache.read(scope, current: () => true), isNull);
    expect(backend.value, isNull);
  });

  test('malformed records clear only the exact observed value', () async {
    final backend = MemoryMusicRetainedCacheBackend()..value = '{bad';
    final cache = ServerMusicRetainedCache(backend: backend);

    expect(await cache.read(scope, current: () => true), isNull);
    expect(backend.clears, 1);
  });

  test('cache rejects float schema and resource revision drift', () async {
    final backend = MemoryMusicRetainedCacheBackend();
    final cache = ServerMusicRetainedCache(
      backend: backend,
      now: () => DateTime.utc(2026, 9, 23, 8),
    );
    final overview = ServerMusicRetainedOverview.fromJson(retainedJson());

    Future<void> rejects(void Function(Map<String, dynamic>) mutate) async {
      expect(await cache.write(scope, overview, current: () => true), isTrue);
      final record = jsonDecode(backend.value!) as Map<String, dynamic>;
      mutate(record);
      backend.value = jsonEncode(record);

      expect(await cache.read(scope, current: () => true), isNull);
      expect(backend.value, isNull);
    }

    await rejects((record) => record['schemaVersion'] = 1.0);
    await rejects(
      (record) =>
          (record['resource'] as Map<String, dynamic>)['contractVersion'] = 1.0,
    );
    await rejects((record) {
      final resource = record['resource'] as Map<String, dynamic>;
      final installation =
          (resource['installations'] as List).single as Map<String, dynamic>;
      installation['installationRevision'] = 4.0;
    });
  });

  test('retired owner cannot publish a delayed cache write', () async {
    final backend = MemoryMusicRetainedCacheBackend();
    final gate = Completer<void>();
    backend.writeGate = gate;
    var current = true;
    final cache = ServerMusicRetainedCache(backend: backend);
    final writing = cache.write(
      scope,
      ServerMusicRetainedOverview.fromJson(retainedJson()),
      current: () => current,
    );
    await Future<void>.delayed(Duration.zero);
    current = false;
    gate.complete();

    expect(await writing, isFalse);
    expect(backend.value, isNull);
    expect(backend.writes, 0);
  });

  test('retired reader never returns its delayed snapshot', () async {
    final backend = MemoryMusicRetainedCacheBackend();
    final cache = ServerMusicRetainedCache(backend: backend);
    await cache.write(
      scope,
      ServerMusicRetainedOverview.fromJson(retainedJson()),
      current: () => true,
    );
    final gate = Completer<void>();
    backend.readGate = gate;
    var current = true;
    final reading = cache.read(scope, current: () => current);
    current = false;
    gate.complete();

    expect(await reading, isNull);
  });
}
