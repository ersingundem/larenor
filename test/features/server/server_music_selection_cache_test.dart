import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/server/music_manager/data/server_music_manager_controller.dart';
import 'package:larenor/features/server/music_manager/data/server_music_selection_cache.dart';
import 'package:larenor/features/server/music_manager/domain/server_music_manager_models.dart';

import 'server_music_manager_test_support.dart';

final class _MemoryBackend implements ServerMusicSelectionCacheBackend {
  String? value;
  int writes = 0, clears = 0;
  Completer<String?>? pendingRead;

  @override
  Future<void> clear() async {
    clears++;
    value = null;
  }

  @override
  Future<String?> read() => pendingRead?.future ?? Future.value(value);

  @override
  Future<void> write(String value) async {
    writes++;
    this.value = value;
  }
}

final class _DelayedWriteBackend implements ServerMusicSelectionCacheBackend {
  String? value;
  final writes = <String>[];
  final gates = <Completer<void>>[];

  @override
  Future<void> clear() async => value = null;

  @override
  Future<String?> read() async => value;

  @override
  Future<void> write(String value) async {
    writes.add(value);
    final gate = Completer<void>();
    gates.add(gate);
    await gate.future;
    this.value = value;
  }
}

const _scope = ServerMusicSelectionScope(
  coreId: '11111111111111111111111111111111',
  homeId: '22222222222222222222222222222222',
  accountId: 'operator@example.test',
);

const _fixtureScope = ServerMusicSelectionScope(
  coreId: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  homeId: 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
  accountId: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
);

Map<String, dynamic> _managerJson({
  int providerRevision = 5,
  String receiverProvider = 'chromecast--main',
}) {
  final value = musicManagerJson();
  (value['providers'] as List).add({
    'setupId': 'e' * 32,
    'revision': providerRevision,
    'providerDomain': 'apple_music',
    'providerInstanceId': 'apple-music--fixture',
    'catalogAvailable': true,
  });
  final receiver = (value['receivers'] as List)
      .cast<Map<String, dynamic>>()
      .singleWhere((item) => item['playerId'] == 'cast-kitchen');
  receiver['provider'] = receiverProvider;
  return value;
}

ServerMusicManager _manager({
  int providerRevision = 5,
  String receiverProvider = 'chromecast--main',
}) => ServerMusicManager.fromJson(
  _managerJson(
    providerRevision: providerRevision,
    receiverProvider: receiverProvider,
  ),
);

ServerMusicManager _oversizedManager() {
  final value = _managerJson();
  final members = [
    for (var index = 0; index < 64; index++)
      'member-${index.toString().padLeft(2, '0')}-${'x' * 110}',
  ];
  value['receivers'] = [
    for (final id in members)
      {
        'playerId': id,
        'name': 'Member',
        'provider': 'airplay--main',
        'targetKind': 'airplay',
        'available': true,
        'enabled': true,
        'playbackState': 'idle',
        'volumeLevel': 20,
        'muted': false,
        'groupMembers': <String>[],
        'queueId': null,
        'positionSeconds': 0.0,
        'capabilities': ['play'],
      },
    {
      'playerId': 'large-group',
      'name': 'Large group',
      'provider': 'airplay--main',
      'targetKind': 'airplay_group',
      'available': true,
      'enabled': true,
      'playbackState': 'idle',
      'volumeLevel': 20,
      'muted': false,
      'groupMembers': members,
      'queueId': null,
      'positionSeconds': 0.0,
      'capabilities': ['play'],
    },
  ];
  return ServerMusicManager.fromJson(value);
}

ServerMusicProviderBinding _provider(ServerMusicManager manager) =>
    manager.providers.singleWhere((item) => item.setupId == 'e' * 32);

ServerMusicReceiver _receiver(ServerMusicManager manager) =>
    manager.receivers.singleWhere((item) => item.id == 'cast-kitchen');

final class _MultiProviderFixture extends MusicManagerFixture {
  @override
  Map<String, dynamic> manager() {
    final value = super.manager();
    (value['providers'] as List).add({
      'setupId': 'e' * 32,
      'revision': 5,
      'providerDomain': 'apple_music',
      'providerInstanceId': 'apple-music--fixture',
      'catalogAvailable': true,
    });
    return value;
  }
}

void main() {
  test('selection cache binds exact tuple, resource, mappings, schema, TTL and quota', () async {
    final backend = _MemoryBackend();
    var now = DateTime.utc(2026, 9, 23, 9);
    final cache = ServerMusicSelectionCache(backend: backend, now: () => now);
    final manager = _manager();
    await cache.write(
      _scope,
      manager,
      provider: _provider(manager),
      receiver: _receiver(manager),
    );

    final restored = await cache.read(_scope, manager);
    expect(restored?.providerId, 'e' * 32);
    expect(restored?.receiverId, 'cast-kitchen');
    expect(restored.toString(), 'ServerMusicSelection(redacted)');
    expect(jsonDecode(backend.value!)['schemaVersion'], 1);
    expect(backend.value, isNot(contains('token')));
    expect(backend.value, isNot(contains('password')));
    expect(backend.value, isNot(contains('Living room HomePod')));

    for (final otherScope in const [
      ServerMusicSelectionScope(
        coreId: '33333333333333333333333333333333',
        homeId: '22222222222222222222222222222222',
        accountId: 'operator@example.test',
      ),
      ServerMusicSelectionScope(
        coreId: '11111111111111111111111111111111',
        homeId: '33333333333333333333333333333333',
        accountId: 'operator@example.test',
      ),
      ServerMusicSelectionScope(
        coreId: '11111111111111111111111111111111',
        homeId: '22222222222222222222222222222222',
        accountId: 'other@example.test',
      ),
    ]) {
      expect(await cache.read(otherScope, manager), isNull);
    }
    expect(await cache.read(_scope, _manager(providerRevision: 6)), isNull);

    await cache.write(
      _scope,
      manager,
      provider: _provider(manager),
      receiver: _receiver(manager),
    );
    expect(
      await cache.read(
        _scope,
        _manager(receiverProvider: 'chromecast--replacement'),
      ),
      isNull,
    );

    await cache.write(
      _scope,
      manager,
      provider: _provider(manager),
      receiver: _receiver(manager),
    );
    now = now.add(ServerMusicSelectionCache.timeToLive);
    expect(await cache.read(_scope, manager), isNull);

    now = DateTime.utc(2026, 9, 23, 9);
    await cache.write(
      _scope,
      manager,
      provider: _provider(manager),
      receiver: _receiver(manager),
    );
    final unknown = jsonDecode(backend.value!) as Map<String, dynamic>;
    unknown['secret'] = 'must-not-be-accepted';
    backend.value = jsonEncode(unknown);
    expect(await cache.read(_scope, manager), isNull);
    expect(backend.value, isNull);

    backend.value = 'x' * (ServerMusicSelectionCache.maximumBytes + 1);
    expect(await cache.read(_scope, manager), isNull);
    expect(backend.value, isNull);

    final oversized = _oversizedManager();
    final writes = backend.writes;
    await expectLater(
      cache.write(
        _scope,
        oversized,
        provider: _provider(oversized),
        receiver: oversized.receivers.last,
      ),
      throwsStateError,
    );
    expect(backend.writes, writes);
  });

  test('explicit provider and receiver choices restore only after live verification', () async {
    final backend = _MemoryBackend();
    final cache = ServerMusicSelectionCache(
      backend: backend,
      now: () => DateTime.utc(2026, 9, 23, 9),
    );
    final fixture = _MultiProviderFixture();
    await fixture.account.initialize();
    final first = ServerMusicManagerController(
      fixture.account,
      selectionCache: cache,
    );
    await first.load(current: () => true);
    await first.verify(current: () => true);
    await first.selectProvider('e' * 32);
    await first.selectReceiver('cast-kitchen');
    expect(backend.writes, 2);
    first.dispose();

    final restarted = ServerMusicManagerController(
      fixture.account,
      selectionCache: ServerMusicSelectionCache(
        backend: backend,
        now: () => DateTime.utc(2026, 9, 23, 9, 1),
      ),
    );
    addTearDown(() {
      restarted.dispose();
      fixture.account.dispose();
    });

    await restarted.load(current: () => true);
    expect(restarted.verified, isFalse);
    expect(restarted.selectedProviderId, 'd' * 32);
    expect(restarted.selectedReceiverId, 'homepod-living');

    await restarted.verify(current: () => true);

    expect(restarted.verified, isTrue);
    expect(restarted.selectedProviderId, 'e' * 32);
    expect(restarted.selectedReceiverId, 'cast-kitchen');
  });

  test('authorization loss discards a delayed selection restore', () async {
    final backend = _MemoryBackend();
    final now = DateTime.utc(2026, 9, 23, 9);
    final cache = ServerMusicSelectionCache(backend: backend, now: () => now);
    final manager = _manager();
    await cache.write(
      _fixtureScope,
      manager,
      provider: _provider(manager),
      receiver: _receiver(manager),
    );
    final persisted = backend.value;
    backend.pendingRead = Completer<String?>();
    final fixture = _MultiProviderFixture();
    await fixture.account.initialize();
    final controller = ServerMusicManagerController(
      fixture.account,
      selectionCache: cache,
    );
    addTearDown(() {
      controller.dispose();
      fixture.account.dispose();
    });
    await controller.load(current: () => true);

    final verifying = controller.verify(current: () => true);
    await Future<void>.delayed(Duration.zero);
    expect(controller.busy, isTrue);
    await fixture.account.signOut();
    backend.pendingRead!.complete(persisted);
    await verifying;

    expect(controller.verified, isFalse);
    expect(controller.manager, isNull);
    expect(controller.selectedProviderId, isNull);
    expect(controller.selectedReceiverId, isNull);
  });

  test(
    'rapid provider choices persist only the latest verified choice',
    () async {
      final backend = _DelayedWriteBackend();
      final fixture = _MultiProviderFixture();
      await fixture.account.initialize();
      final controller = ServerMusicManagerController(
        fixture.account,
        selectionCache: ServerMusicSelectionCache(backend: backend),
      );
      addTearDown(() {
        controller.dispose();
        fixture.account.dispose();
      });
      await controller.load(current: () => true);
      await controller.verify(current: () => true);

      final older = controller.selectProvider('e' * 32);
      await Future<void>.delayed(Duration.zero);
      final latest = controller.selectProvider('d' * 32);
      await Future<void>.delayed(Duration.zero);
      expect(backend.writes, hasLength(2));
      backend.gates[1].complete();
      await latest;
      backend.gates[0].complete();
      await older;

      final restored = await ServerMusicSelectionCache(backend: backend)
          .read(_fixtureScope, _manager());
      expect(restored?.providerId, 'd' * 32);
    },
  );

  test(
    'rapid receiver choices persist only the latest verified choice',
    () async {
      final backend = _DelayedWriteBackend();
      final fixture = _MultiProviderFixture();
      await fixture.account.initialize();
      final controller = ServerMusicManagerController(
        fixture.account,
        selectionCache: ServerMusicSelectionCache(backend: backend),
      );
      addTearDown(() {
        controller.dispose();
        fixture.account.dispose();
      });
      await controller.load(current: () => true);
      await controller.verify(current: () => true);

      final older = controller.selectReceiver('cast-kitchen');
      await Future<void>.delayed(Duration.zero);
      final latest = controller.selectReceiver('homepod-living');
      await Future<void>.delayed(Duration.zero);
      expect(backend.writes, hasLength(2));
      backend.gates[1].complete();
      await latest;
      backend.gates[0].complete();
      await older;

      final restored = await ServerMusicSelectionCache(backend: backend)
          .read(_fixtureScope, _manager());
      expect(restored?.receiverId, 'homepod-living');
    },
  );

  test('logout during a delayed save leaves no restorable selection', () async {
    final backend = _DelayedWriteBackend();
    final fixture = _MultiProviderFixture();
    await fixture.account.initialize();
    final controller = ServerMusicManagerController(
      fixture.account,
      selectionCache: ServerMusicSelectionCache(backend: backend),
    );
    addTearDown(() {
      controller.dispose();
      fixture.account.dispose();
    });
    await controller.load(current: () => true);
    await controller.verify(current: () => true);

    final saving = controller.selectProvider('e' * 32);
    await Future<void>.delayed(Duration.zero);
    await fixture.account.signOut();
    backend.gates.single.complete();
    await saving;
    await Future<void>.delayed(Duration.zero);

    expect(
      await ServerMusicSelectionCache(backend: backend)
          .read(_fixtureScope, _manager()),
      isNull,
    );
  });
}
