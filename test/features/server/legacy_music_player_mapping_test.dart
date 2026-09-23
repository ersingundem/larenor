import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/media/music/domain/music_models.dart';
import 'package:larenor/features/server/music_manager/data/legacy_music_player_mapping.dart';
import 'package:larenor/features/server/music_manager/data/server_music_selection_cache.dart';
import 'package:larenor/features/server/music_manager/domain/server_music_manager_models.dart';

import 'server_music_manager_test_support.dart';

final class _MemoryBackend implements ServerMusicSelectionCacheBackend {
  String? value;
  int writes = 0, clears = 0;
  Completer<void>? gate;
  Completer<void>? started;
  String? replacementBeforeClear;

  @override
  Future<void> clear() async {
    clears++;
    value = null;
  }

  @override
  Future<bool> compareAndClear(String expected) async {
    final replacement = replacementBeforeClear;
    replacementBeforeClear = null;
    if (replacement != null) value = replacement;
    if (value != expected) return false;
    clears++;
    value = null;
    return true;
  }

  @override
  Future<bool> compareAndWrite(String? expected, String next) async {
    started?.complete();
    await gate?.future;
    if (value != expected) return false;
    writes++;
    value = next;
    return true;
  }

  @override
  Future<String?> read() async => value;
}

const _legacyTarget = MusicQueueTarget(
  entityId: 'media_player.living_room',
  configEntryId: 'legacy-ma-entry',
  name: 'Living room speaker',
  registryId: 'legacy-registry-player',
  deviceId: 'legacy-device',
  available: true,
  enabled: true,
);

MusicDiscovery _discovery({
  Object? generation,
  DateTime? readAt,
  MusicQueueTarget target = _legacyTarget,
  Map<MusicDiscoverySource, MusicFailure> issues = const {},
}) => MusicDiscovery(
  accountGeneration: generation ?? _directGeneration,
  readAt: readAt ?? DateTime.utc(2026, 9, 23, 10),
  entries: const [
    MusicAssistantEntry(
      id: 'legacy-ma-entry',
      title: 'Old Music Assistant',
      state: 'loaded',
      disabled: false,
    ),
  ],
  queueTargets: [target],
  issues: issues,
);

final _directGeneration = Object();

ServerMusicManager _manager() =>
    ServerMusicManager.fromJson(musicManagerJson());

void main() {
  test(
    'preview exposes only a fresh secret-free legacy player label',
    () async {
      final fixture = MusicManagerFixture();
      await fixture.account.initialize();
      addTearDown(fixture.account.dispose);
      final migration = LegacyMusicPlayerMapping(
        account: fixture.account,
        loadLegacyDiscovery: () async => _discovery(),
        now: () => DateTime.utc(2026, 9, 23, 10, 1),
      );
      addTearDown(migration.dispose);

      final receipt = await migration.prepare(
        _legacyTarget,
        current: () => true,
      );

      expect(receipt, isNotNull);
      expect(receipt!.preview.name, 'Living room speaker');
      expect(receipt.preview.requiresExplicitCoreSelection, isTrue);
      expect(receipt.toString(), 'Legacy music player mapping');
      expect(receipt.preview.toString(), 'Legacy music player preview');
      expect(receipt.toString(), isNot(contains('media_player')));
      expect(receipt.toString(), isNot(contains('legacy-ma-entry')));
      expect(receipt.toString(), isNot(contains('legacy-registry-player')));
    },
  );

  test(
    'stale partial and unstable legacy players do not create a preview',
    () async {
      final fixtures = <MusicDiscovery>[
        _discovery(readAt: DateTime.utc(2026, 9, 23, 9, 57)),
        _discovery(
          issues: const {MusicDiscoverySource.registry: MusicFailure.transport},
        ),
        _discovery(
          target: const MusicQueueTarget(
            entityId: 'media_player.living_room',
            configEntryId: 'legacy-ma-entry',
            name: 'Living room speaker',
            registryId: null,
            available: true,
            enabled: true,
          ),
        ),
        _discovery(
          target: const MusicQueueTarget(
            entityId: 'media_player.living_room',
            configEntryId: 'legacy-ma-entry',
            name: 'Living room speaker',
            registryId: 'legacy-registry-player',
            available: false,
            enabled: true,
          ),
        ),
      ];

      for (final discovery in fixtures) {
        final fixture = MusicManagerFixture();
        await fixture.account.initialize();
        final migration = LegacyMusicPlayerMapping(
          account: fixture.account,
          loadLegacyDiscovery: () async => discovery,
          now: () => DateTime.utc(2026, 9, 23, 10, 1),
        );
        expect(
          await migration.prepare(
            discovery.queueTargets.single,
            current: () => true,
          ),
          isNull,
          reason: '${discovery.readAt} ${discovery.issues}',
        );
        migration.dispose();
        fixture.account.dispose();
      }
    },
  );

  test('explicit confirmation refreshes Core and persists only the chosen central pair', () async {
    final fixture = MusicManagerFixture();
    await fixture.account.initialize();
    addTearDown(fixture.account.dispose);
    final backend = _MemoryBackend();
    final cache = ServerMusicSelectionCache(
      backend: backend,
      now: () => DateTime.utc(2026, 9, 23, 10, 1),
    );
    final migration = LegacyMusicPlayerMapping(
      account: fixture.account,
      loadLegacyDiscovery: () async => _discovery(),
      selectionCache: cache,
      requestId: () => 'f' * 32,
      now: () => DateTime.utc(2026, 9, 23, 10, 1),
    );
    addTearDown(migration.dispose);
    final manager = _manager();
    final provider = manager.providers.single;
    final receiver = manager.receivers.singleWhere(
      (item) => item.id == 'cast-kitchen',
    );
    final receipt = (await migration.prepare(
      _legacyTarget,
      current: () => true,
    ))!;

    await migration.confirm(
      receipt,
      manager: manager,
      provider: provider,
      receiver: receiver,
      current: () => true,
    );

    final scope = ServerMusicSelectionScope.fromSession(
      fixture.account.session!,
    );
    final stored = await cache.read(scope, manager);
    expect(stored?.providerId, provider.setupId);
    expect(stored?.receiverId, 'cast-kitchen');
    expect(backend.value, isNot(contains('media_player.living_room')));
    expect(backend.value, isNot(contains('legacy-ma-entry')));
    expect(backend.value, isNot(contains('Living room speaker')));
    final refresh = fixture.calls.singleWhere(
      (call) => call.url.path.endsWith('/manager/refresh'),
    );
    expect(jsonDecode(refresh.body), {
      'requestId': 'f' * 32,
      'installationId': manager.installationId,
      'expectedInstallationRevision': manager.installationRevision,
      'expectedCoreRevision': manager.coreRevision,
    });
    expect(refresh.body, isNot(contains('media_player.living_room')));
    expect(refresh.body, isNot(contains('legacy-ma-entry')));
    expect(refresh.body, isNot(contains('Living room speaker')));

    await expectLater(
      migration.confirm(
        receipt,
        manager: manager,
        provider: provider,
        receiver: receiver,
        current: () => true,
      ),
      throwsStateError,
    );
  });

  test(
    'legacy source drift fails before a Core refresh or persistence',
    () async {
      final fixture = MusicManagerFixture();
      await fixture.account.initialize();
      addTearDown(fixture.account.dispose);
      var discovery = _discovery();
      final backend = _MemoryBackend();
      final migration = LegacyMusicPlayerMapping(
        account: fixture.account,
        loadLegacyDiscovery: () async => discovery,
        selectionCache: ServerMusicSelectionCache(backend: backend),
        now: () => DateTime.utc(2026, 9, 23, 10, 1),
      );
      addTearDown(migration.dispose);
      final receipt = (await migration.prepare(
        _legacyTarget,
        current: () => true,
      ))!;
      discovery = _discovery(
        target: const MusicQueueTarget(
          entityId: 'media_player.living_room',
          configEntryId: 'legacy-ma-entry',
          name: 'Renamed speaker',
          registryId: 'legacy-registry-player',
          deviceId: 'legacy-device',
          available: true,
          enabled: true,
        ),
      );
      final manager = _manager();

      await expectLater(
        migration.confirm(
          receipt,
          manager: manager,
          provider: manager.providers.single,
          receiver: manager.receivers.first,
          current: () => true,
        ),
        throwsStateError,
      );

      expect(
        fixture.calls.where(
          (call) => call.url.path.endsWith('/manager/refresh'),
        ),
        isEmpty,
      );
      expect(backend.writes, 0);
    },
  );

  test('one receipt has one in-flight central target owner', () async {
    final fixture = MusicManagerFixture();
    await fixture.account.initialize();
    addTearDown(fixture.account.dispose);
    final backend = _MemoryBackend()
      ..gate = Completer<void>()
      ..started = Completer<void>();
    final migration = LegacyMusicPlayerMapping(
      account: fixture.account,
      loadLegacyDiscovery: () async => _discovery(),
      selectionCache: ServerMusicSelectionCache(backend: backend),
      now: () => DateTime.utc(2026, 9, 23, 10, 1),
    );
    addTearDown(migration.dispose);
    final receipt = (await migration.prepare(
      _legacyTarget,
      current: () => true,
    ))!;
    final manager = _manager();
    final first = migration.confirm(
      receipt,
      manager: manager,
      provider: manager.providers.single,
      receiver: manager.receivers.first,
      current: () => true,
    );
    await backend.started!.future;

    await expectLater(
      migration.confirm(
        receipt,
        manager: manager,
        provider: manager.providers.single,
        receiver: manager.receivers[1],
        current: () => true,
      ),
      throwsStateError,
    );
    expect(backend.writes, 0);
    backend.gate!.complete();
    await first;

    expect(backend.writes, 1);
    expect(
      fixture.calls.where((call) => call.url.path.endsWith('/manager/refresh')),
      hasLength(1),
    );
  });

  test('authority retirement during persistence retracts only the exact mapping write', () async {
    final fixture = MusicManagerFixture();
    await fixture.account.initialize();
    addTearDown(fixture.account.dispose);
    final backend = _MemoryBackend()
      ..gate = Completer<void>()
      ..started = Completer<void>()
      ..replacementBeforeClear = 'replacement-owner-snapshot';
    final migration = LegacyMusicPlayerMapping(
      account: fixture.account,
      loadLegacyDiscovery: () async => _discovery(),
      selectionCache: ServerMusicSelectionCache(backend: backend),
      now: () => DateTime.utc(2026, 9, 23, 10, 1),
    );
    addTearDown(migration.dispose);
    final receipt = (await migration.prepare(
      _legacyTarget,
      current: () => true,
    ))!;
    final manager = _manager();
    var current = true;
    final confirming = migration.confirm(
      receipt,
      manager: manager,
      provider: manager.providers.single,
      receiver: manager.receivers.first,
      current: () => current,
    );
    await backend.started!.future;
    current = false;
    backend.gate!.complete();

    await expectLater(confirming, throwsStateError);
    expect(backend.value, 'replacement-owner-snapshot');
    expect(backend.writes, 1);
    expect(backend.clears, 0);
  });
}
