import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/server/music_manager/data/server_music_manager_cache.dart';
import 'package:larenor/features/server/music_manager/data/server_music_manager_controller.dart';
import 'package:larenor/features/server/music_manager/domain/server_music_manager_models.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

import 'server_music_manager_test_support.dart';

final class _MemoryBackend implements ServerMusicManagerCacheBackend {
  String? value;
  int writes = 0, clears = 0;
  String? replacementBeforeMutation;
  Completer<void>? mutationGate;
  Completer<void>? mutationStarted;

  Future<void> _gate() async {
    mutationStarted?.complete();
    await mutationGate?.future;
  }

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
  Future<bool> compareAndWrite(
    String? expected,
    String value, {
    required bool Function() current,
  }) async {
    await _gate();
    if (!current()) return false;
    final replacement = replacementBeforeMutation;
    replacementBeforeMutation = null;
    if (replacement != null) this.value = replacement;
    if (this.value != expected || !current()) return false;
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
    await _gate();
    writes++;
    this.value = value;
  }
}

final class _DelayedPreferences extends InMemorySharedPreferencesStore {
  _DelayedPreferences() : super.empty();

  final started = Completer<void>();
  final gate = Completer<void>();
  Future<void> Function(String key)? afterPersist;

  @override
  Future<bool> setValue(String type, String key, Object value) async {
    if (!started.isCompleted) started.complete();
    await gate.future;
    final result = await super.setValue(type, key, value);
    await afterPersist?.call(key);
    return result;
  }

  Future<void> replace(String key, String value) =>
      super.setValue('String', key, value);
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
  TestWidgetsFlutterBinding.ensureInitialized();

  test('SharedPreferences backend survives a fresh cache backend', () async {
    SharedPreferences.setMockInitialValues({});
    final writer = SharedPreferencesServerMusicManagerCacheBackend();
    await writer.write('snapshot');

    final reader = SharedPreferencesServerMusicManagerCacheBackend();
    expect(await reader.read(), 'snapshot');

    await reader.clear();
    expect(await writer.read(), isNull);
  });

  test('SharedPreferences backend retracts its exact write when lifecycle retires during setString', () async {
    SharedPreferences.resetStatic();
    final previous = SharedPreferencesStorePlatform.instance;
    final preferences = _DelayedPreferences();
    SharedPreferencesStorePlatform.instance = preferences;
    addTearDown(() {
      SharedPreferencesStorePlatform.instance = previous;
      SharedPreferences.resetStatic();
    });
    var current = true;
    final backend = SharedPreferencesServerMusicManagerCacheBackend();

    final writing = backend.compareAndWrite(
      null,
      'retired-snapshot',
      current: () => current,
    );
    await preferences.started.future;
    current = false;
    preferences.gate.complete();

    expect(await writing, isFalse);
    expect(await backend.read(), isNull);
  });

  test(
    'post-write retirement preserves a replacement owner snapshot',
    () async {
      SharedPreferences.resetStatic();
      final previous = SharedPreferencesStorePlatform.instance;
      final preferences = _DelayedPreferences();
      SharedPreferencesStorePlatform.instance = preferences;
      addTearDown(() {
        SharedPreferencesStorePlatform.instance = previous;
        SharedPreferences.resetStatic();
      });
      var current = true;
      preferences.afterPersist = (key) async {
        current = false;
        await preferences.replace(key, 'replacement-snapshot');
      };
      final backend = SharedPreferencesServerMusicManagerCacheBackend();
      final writing = backend.compareAndWrite(
        null,
        'retired-snapshot',
        current: () => current,
      );
      await preferences.started.future;
      preferences.gate.complete();

      expect(await writing, isFalse);
      expect(await backend.read(), 'replacement-snapshot');
    },
  );

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

  test(
    'manager unauthorized retires both cached manager and account session',
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
            'error': {'code': 'unauthorized'},
          }, 401);
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

      expect(restarted.manager, isNull);
      expect(restarted.reachable, false);
      expect(restarted.verified, false);
      expect(fixture.account.session, isNull);
      expect(fixture.account.failure, 'unauthorized');
    },
  );

  test(
    'malformed expired and oversized cleanup preserves a replacement owner',
    () async {
      for (final invalid in ['malformed', 'expired', 'oversized']) {
        final backend = _MemoryBackend();
        var now = DateTime.utc(2026, 9, 23, 8);
        final cache = ServerMusicManagerCache(backend: backend, now: () => now);
        final manager = _manager();
        await cache.write(_scope, manager);
        final valid = backend.value!;
        final replacement = '$valid ';

        switch (invalid) {
          case 'malformed':
            final record = jsonDecode(valid) as Map<String, dynamic>;
            record['unexpected'] = true;
            backend.value = jsonEncode(record);
          case 'expired':
            backend.value = valid;
            now = now.add(ServerMusicManagerCache.timeToLive);
          case 'oversized':
            backend.value = 'x' * (ServerMusicManagerCache.maximumBytes + 1);
        }
        backend.replacementBeforeMutation = replacement;

        expect(await _read(cache, manager), isNull, reason: invalid);
        expect(backend.value, replacement, reason: invalid);
      }
    },
  );

  test('a stale writer cannot replace a newer manager snapshot', () async {
    final backend = _MemoryBackend();
    final cache = ServerMusicManagerCache(
      backend: backend,
      now: () => DateTime.utc(2026, 9, 23, 8),
    );
    await cache.write(_scope, _manager());
    final stale = backend.value!;
    final newer = ServerMusicManager.fromJson(musicManagerJson(revision: 7));
    await cache.write(_scope, newer);
    final replacement = backend.value!;
    backend.value = stale;
    backend.replacementBeforeMutation = replacement;

    await cache.write(_scope, _manager());

    expect(backend.value, replacement);
    expect(await _read(cache, newer), isNotNull);
  });

  test('schema and resource revisions require exact integers', () async {
    for (final field in [
      'schemaVersion',
      'resource.installationRevision',
      'resource.coreRevision',
      'resource.managerRevision',
    ]) {
      final backend = _MemoryBackend();
      final cache = ServerMusicManagerCache(
        backend: backend,
        now: () => DateTime.utc(2026, 9, 23, 8),
      );
      final manager = _manager();
      await cache.write(_scope, manager);
      final record = jsonDecode(backend.value!) as Map<String, dynamic>;
      if (field == 'schemaVersion') {
        record['schemaVersion'] = 1.0;
      } else {
        final resource = record['resource'] as Map<String, dynamic>;
        final key = field.split('.').last;
        resource[key] = (resource[key] as int).toDouble();
      }
      backend.value = jsonEncode(record);

      expect(await _read(cache, manager), isNull, reason: field);
      expect(backend.value, isNull, reason: field);
    }
  });

  test('retired controller cannot complete a delayed cache mutation', () async {
    final backend = _MemoryBackend()
      ..mutationGate = Completer<void>()
      ..mutationStarted = Completer<void>();
    final fixture = MusicManagerFixture();
    await fixture.account.initialize();
    final controller = ServerMusicManagerController(
      fixture.account,
      cache: ServerMusicManagerCache(
        backend: backend,
        now: () => DateTime.utc(2026, 9, 23, 8),
      ),
    );
    addTearDown(() {
      controller.dispose();
      fixture.account.dispose();
    });

    final loading = controller.load(current: () => true);
    await backend.mutationStarted!.future;
    controller.invalidate();
    backend.mutationGate!.complete();
    await loading;

    expect(backend.writes, 0);
    expect(backend.value, isNull);
  });
}
