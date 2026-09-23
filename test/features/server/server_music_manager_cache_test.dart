import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/server/music_manager/data/server_music_manager_cache.dart';
import 'package:larenor/features/server/music_manager/data/server_music_manager_controller.dart';
import 'package:larenor/features/server/music_manager/domain/server_music_manager_models.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'server_music_manager_test_support.dart';

final class _MemoryBackend implements ServerMusicManagerCacheBackend {
  String? value;
  int writes = 0, clears = 0;

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

const _scope = ServerMusicManagerCacheScope(
  coreId: '11111111111111111111111111111111',
  homeId: '22222222222222222222222222222222',
  accountId: 'operator@example.test',
);

ServerMusicManager _manager() =>
    ServerMusicManager.fromJson(musicManagerJson());

ServerMusicManager _oversizedManager() {
  final ids = List.generate(
    256,
    (index) => 'player-${index.toString().padLeft(3, '0')}-${'x' * 115}',
  );
  final value = musicManagerJson();
  value['receivers'] = [
    for (final id in ids)
      {
        'playerId': id,
        'name': 'N' * 160,
        'provider': 'provider-${'x' * 119}',
        'targetKind': 'group',
        'available': true,
        'enabled': true,
        'playbackState': 'idle',
        'volumeLevel': 25,
        'muted': false,
        'groupMembers': ids.take(64).toList(),
        'queueId': null,
        'positionSeconds': 0.0,
        'capabilities': ['play', 'pause', 'seek', 'stop', 'queue'],
      },
  ];
  return ServerMusicManager.fromJson(value);
}

Future<ServerMusicManager?> _read(
  ServerMusicManagerCache cache,
  ServerMusicManager manager, {
  ServerMusicManagerCacheScope scope = _scope,
  String? installationId,
  int? installationRevision,
  int? coreRevision,
}) => cache.read(
  scope,
  installationId: installationId ?? manager.installationId,
  installationRevision: installationRevision ?? manager.installationRevision,
  coreRevision: coreRevision ?? manager.coreRevision,
);

void main() {
  test('SharedPreferences backend survives a fresh cache backend', () async {
    SharedPreferences.setMockInitialValues({});
    final writer = SharedPreferencesServerMusicManagerCacheBackend();
    await writer.write('snapshot');

    final reader = SharedPreferencesServerMusicManagerCacheBackend();
    expect(await reader.read(), 'snapshot');

    await reader.clear();
    expect(await writer.read(), isNull);
  });

  test(
    'cache binds exact scope, resource revisions, schema, TTL and quota',
    () async {
      final backend = _MemoryBackend();
      var now = DateTime.utc(2026, 9, 23, 8);
      final cache = ServerMusicManagerCache(backend: backend, now: () => now);
      final manager = _manager();

      await cache.write(_scope, manager);

      expect(
        await _read(
          ServerMusicManagerCache(backend: backend, now: () => now),
          manager,
        ),
        isNotNull,
      );
      expect(jsonDecode(backend.value!)['schemaVersion'], 1);
      expect(backend.value, isNot(contains('token')));
      expect(backend.value, isNot(contains('password')));

      for (final otherScope in const [
        ServerMusicManagerCacheScope(
          coreId: '33333333333333333333333333333333',
          homeId: '22222222222222222222222222222222',
          accountId: 'operator@example.test',
        ),
        ServerMusicManagerCacheScope(
          coreId: '11111111111111111111111111111111',
          homeId: '33333333333333333333333333333333',
          accountId: 'operator@example.test',
        ),
        ServerMusicManagerCacheScope(
          coreId: '11111111111111111111111111111111',
          homeId: '22222222222222222222222222222222',
          accountId: 'other@example.test',
        ),
      ]) {
        expect(await _read(cache, manager, scope: otherScope), isNull);
      }
      expect(await _read(cache, manager, installationId: 'f' * 32), isNull);
      expect(
        await _read(
          cache,
          manager,
          installationRevision: manager.installationRevision + 1,
        ),
        isNull,
      );
      expect(
        await _read(cache, manager, coreRevision: manager.coreRevision + 1),
        isNull,
      );

      now = now.add(ServerMusicManagerCache.timeToLive);
      expect(await _read(cache, manager), isNull);

      await cache.write(_scope, manager);
      final wrongSchema = jsonDecode(backend.value!) as Map<String, dynamic>;
      wrongSchema['schemaVersion'] = 2;
      backend.value = jsonEncode(wrongSchema);
      expect(await _read(cache, manager), isNull);
      expect(backend.value, isNull);

      await cache.write(_scope, manager);
      final wrongManagerRevision =
          jsonDecode(backend.value!) as Map<String, dynamic>;
      (wrongManagerRevision['resource']
              as Map<String, dynamic>)['managerRevision'] =
          manager.revision + 1;
      backend.value = jsonEncode(wrongManagerRevision);
      expect(await _read(cache, manager), isNull);
      expect(backend.value, isNull);

      backend.value = 'x' * (ServerMusicManagerCache.maximumBytes + 1);
      expect(await _read(cache, manager), isNull);
      expect(backend.value, isNull);

      final writes = backend.writes;
      await expectLater(
        cache.write(_scope, _oversizedManager()),
        throwsA(isA<StateError>()),
      );
      expect(backend.writes, writes);
    },
  );

  test(
    'controller restores only an unverified cached manager after restart',
    () async {
      final backend = _MemoryBackend();
      final cache = ServerMusicManagerCache(
        backend: backend,
        now: () => DateTime.utc(2026, 9, 23, 8),
      );
      final fixture = MusicManagerFixture();
      await fixture.account.initialize();
      final first = ServerMusicManagerController(fixture.account, cache: cache);
      await first.load(current: () => true);
      expect(first.reachable, true);
      expect(backend.writes, 1);
      first.dispose();

      final original = fixture.respond!;
      fixture.respond = (request) async {
        if (request.method == 'GET' && request.url.path.contains('/manager/')) {
          return fixture.json({'code': 'server_error'}, 500);
        }
        return original(request);
      };
      final restarted = ServerMusicManagerController(
        fixture.account,
        cache: ServerMusicManagerCache(
          backend: backend,
          now: () => DateTime.utc(2026, 9, 23, 8, 1),
        ),
      );
      addTearDown(() {
        restarted.dispose();
        fixture.account.dispose();
      });

      await restarted.load(current: () => true);

      expect(restarted.manager?.installationId, 'a' * 32);
      expect(restarted.stored, true);
      expect(restarted.reachable, false);
      expect(restarted.verified, false);
      expect(restarted.failure, 'server_error');
    },
  );

  test(
    'manager authorization loss never publishes the retained cached snapshot',
    () async {
      final backend = _MemoryBackend();
      final cache = ServerMusicManagerCache(
        backend: backend,
        now: () => DateTime.utc(2026, 9, 23, 8),
      );
      final fixture = MusicManagerFixture();
      await fixture.account.initialize();
      final first = ServerMusicManagerController(fixture.account, cache: cache);
      await first.load(current: () => true);
      expect(backend.writes, 1);
      first.dispose();

      final original = fixture.respond!;
      fixture.respond = (request) async {
        if (request.method == 'GET' && request.url.path.contains('/manager/')) {
          return fixture.json({
            'error': {'code': 'forbidden'},
          }, 403);
        }
        return original(request);
      };
      final restarted = ServerMusicManagerController(
        fixture.account,
        cache: ServerMusicManagerCache(
          backend: backend,
          now: () => DateTime.utc(2026, 9, 23, 8, 1),
        ),
      );
      addTearDown(() {
        restarted.dispose();
        fixture.account.dispose();
      });

      await restarted.load(current: () => true);

      expect(restarted.stored, true);
      expect(restarted.manager, isNull);
      expect(restarted.reachable, false);
      expect(restarted.verified, false);
      expect(restarted.failure, 'forbidden');
    },
  );
}
