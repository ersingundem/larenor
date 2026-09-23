import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/server/music_manager/data/server_music_manager_cache.dart';
import 'package:larenor/features/server/music_manager/data/server_music_manager_controller.dart';
import 'package:larenor/features/server/music_manager/domain/server_music_manager_models.dart';

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

ServerMusicManager _manager() => ServerMusicManager.fromJson(
  musicManagerJson(),
);

void main() {
  test('cache binds exact scope, resource revisions, schema, TTL and quota', () async {
    final backend = _MemoryBackend();
    var now = DateTime.utc(2026, 9, 23, 8);
    final cache = ServerMusicManagerCache(
      backend: backend,
      now: () => now,
    );
    final manager = _manager();

    await cache.write(_scope, manager);

    expect(
      await ServerMusicManagerCache(
        backend: backend,
        now: () => now,
      ).read(
        _scope,
        installationId: manager.installationId,
        installationRevision: manager.installationRevision,
        coreRevision: manager.coreRevision,
      ),
      isNotNull,
    );
    expect(jsonDecode(backend.value!)['schemaVersion'], 1);
    expect(backend.value, isNot(contains('token')));
    expect(backend.value, isNot(contains('password')));

    const otherAccount = ServerMusicManagerCacheScope(
      coreId: '11111111111111111111111111111111',
      homeId: '22222222222222222222222222222222',
      accountId: 'other@example.test',
    );
    expect(
      await cache.read(
        otherAccount,
        installationId: manager.installationId,
        installationRevision: manager.installationRevision,
        coreRevision: manager.coreRevision,
      ),
      isNull,
    );
    expect(
      await cache.read(
        _scope,
        installationId: 'f' * 32,
        installationRevision: manager.installationRevision,
        coreRevision: manager.coreRevision,
      ),
      isNull,
    );

    now = now.add(ServerMusicManagerCache.timeToLive);
    expect(
      await cache.read(
        _scope,
        installationId: manager.installationId,
        installationRevision: manager.installationRevision,
        coreRevision: manager.coreRevision,
      ),
      isNull,
    );

    backend.value = 'x' * (ServerMusicManagerCache.maximumBytes + 1);
    expect(
      await cache.read(
        _scope,
        installationId: manager.installationId,
        installationRevision: manager.installationRevision,
        coreRevision: manager.coreRevision,
      ),
      isNull,
    );
    expect(backend.value, isNull);
  });

  test('controller restores only an unverified cached manager after restart', () async {
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
  });
}
