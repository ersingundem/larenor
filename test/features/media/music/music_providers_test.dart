// Reproduce retained loading/error configuration without exposing credentials.
// ignore_for_file: invalid_use_of_internal_member
import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/auth/data/ha_connection_config.dart';
import 'package:larenor/features/auth/providers/auth_providers.dart';
import 'package:larenor/features/media/ha_playback/providers/ha_playback_providers.dart';
import 'package:larenor/features/media/music/data/music_queue_controller.dart';
import 'package:larenor/features/media/music/data/music_parser.dart';
import 'package:larenor/features/media/music/domain/music_models.dart';
import 'package:larenor/features/media/music/providers/music_providers.dart';

import 'music_fixtures.dart';

const config = HaConnectionConfig(
  baseUrl: 'http://fixture.invalid',
  token: 'fixture',
);
const otherConfig = HaConnectionConfig(
  baseUrl: 'http://other.invalid',
  token: 'other-fixture',
);

class Connection extends ConnectionConfig {
  @override
  Future<HaConnectionConfig?> build() async => config;
  void replace(AsyncValue<HaConnectionConfig?> value) => state = value;
}

class Fixture {
  Fixture() {
    container = ProviderContainer(
      overrides: [
        connectionConfigProvider.overrideWith(Connection.new),
        musicAssistantApiProvider.overrideWithValue(api),
        musicClockProvider.overrideWithValue(() => now),
        haMediaInventoryProvider.overrideWith((ref) async {
          final config = ref.watch(connectionConfigProvider);
          if (config.isLoading || config.hasError || config.value == null) {
            return null;
          }
          inventoryReads++;
          return musicInventory(readAt: now);
        }),
      ],
    );
  }
  bool closed = false;
  void dispose() {
    if (!closed) {
      closed = true;
      container.dispose();
    }
  }

  late ProviderContainer container;
  final api = FakeMusicApi();
  var inventoryReads = 0;
  var now = musicTime;
  Connection get connection =>
      container.read(connectionConfigProvider.notifier) as Connection;
  Future<MusicDiscovery> ready(WidgetTester tester) async {
    container.listen(musicDiscoveryProvider, (_, _) {});
    await container.read(connectionConfigProvider.future);
    await tester.pump();
    return container.read(musicDiscoveryProvider.future);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  Future<void> foreground(WidgetTester tester) async {
    _resume(tester);
    await tester.pump();
  }

  for (final loading in [true, false]) {
    testWidgets(
      'retained ${loading ? 'loading' : 'error'} removes old repo/results; settled account recovers',
      (tester) async {
        await foreground(tester);
        final fixture = Fixture();
        addTearDown(fixture.dispose);

        final discovery = await fixture.ready(tester);
        final oldRepo = fixture.container.read(musicRepositoryProvider)!;
        final query = MusicLibraryQuery(
          accountGeneration: discovery.accountGeneration,
          configEntryId: 'entry',
          type: MusicMediaType.track,
        );
        final sub = fixture.container.listen(
          musicLibraryProvider(query),
          (_, _) {},
        );
        await fixture.container.read(musicLibraryProvider(query).future);
        expect(fixture.api.libraryReads, 1);
        final prior = fixture.container.read(connectionConfigProvider);
        fixture.connection.replace(
          loading
              ? const AsyncLoading<HaConnectionConfig?>().copyWithPrevious(
                  prior,
                )
              : AsyncError<HaConnectionConfig?>(
                  StateError('private'),
                  StackTrace.current,
                ).copyWithPrevious(prior),
        );
        expect(fixture.container.read(musicRepositoryProvider), isNull);
        expect(oldRepo.current, isFalse);
        await tester.pump();
        final blocked = await fixture.container.read(
          musicLibraryProvider(query).future,
        );
        expect(blocked.value, isNull);
        expect(blocked.failure, MusicFailure.notConfigured);
        fixture.connection.replace(const AsyncData(config));
        await tester.pump();
        final fresh = await fixture.container.read(
          musicDiscoveryProvider.future,
        );
        expect(
          identical(fresh.accountGeneration, discovery.accountGeneration),
          isFalse,
        );
        final staleQuery = await fixture.container.read(
          musicLibraryProvider(query).future,
        );
        expect(staleQuery.value, isNull);
        expect(staleQuery.failure, MusicFailure.invalidSelection);
        final freshQuery = MusicLibraryQuery(
          accountGeneration: fresh.accountGeneration,
          configEntryId: 'entry',
          type: MusicMediaType.track,
        );
        final freshSub = fixture.container.listen(
          musicLibraryProvider(freshQuery),
          (_, _) {},
        );
        expect(
          (await fixture.container.read(
            musicLibraryProvider(freshQuery).future,
          )).value!.items,
          hasLength(1),
        );
        sub.close();
        freshSub.close();
        fixture.dispose();
        await tester.pump();
      },
    );
  }
  testWidgets(
    'shared inventory one read; repository refresh updates aged inventory',
    (tester) async {
      await foreground(tester);
      final fixture = Fixture();
      addTearDown(fixture.dispose);
      final inventorySub = fixture.container.listen(
        haMediaInventoryProvider,
        (_, _) {},
      );
      final discovery = await fixture.ready(tester);
      expect(fixture.inventoryReads, 1);
      expect(discovery.inventory, isNotNull);
      fixture.now = fixture.now.add(const Duration(seconds: 61));
      await fixture.container.read(musicRepositoryProvider)!.discover();
      expect(fixture.inventoryReads, 2);
      inventorySub.close();
      fixture.dispose();
      await tester.pump();
    },
  );
  testWidgets(
    'old library result cannot cross account; delayed search stops before send',
    (tester) async {
      await foreground(tester);
      final fixture = Fixture();
      addTearDown(fixture.dispose);
      final discovery = await fixture.ready(tester);
      fixture.api.libraryGate = Completer<Object?>();
      final query = MusicLibraryQuery(
        accountGeneration: discovery.accountGeneration,
        configEntryId: 'entry',
        type: MusicMediaType.track,
      );
      final sub = fixture.container.listen(
        musicLibraryProvider(query),
        (_, _) {},
      );
      await tester.pump();
      expect(fixture.api.libraryReads, 1);
      final search = MusicSearchQuery(
        accountGeneration: discovery.accountGeneration,
        configEntryId: 'entry',
        text: 'Song',
      );
      final searchSub = fixture.container.listen(
        musicSearchProvider(search),
        (_, _) {},
      );
      fixture.connection.replace(const AsyncData(otherConfig));
      await tester.pump();
      fixture.api.libraryGate!.complete(musicLibrary(query));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 301));
      final value = fixture.container.read(musicLibraryProvider(query)).value;
      expect(value?.value, isNull);
      expect(fixture.api.libraryReads, 1);
      expect(fixture.api.searchReads, 0);
      searchSub.close();
      sub.close();
      fixture.dispose();
      await tester.pump();
    },
  );
  testWidgets('disposed search keystroke family makes no network request', (
    tester,
  ) async {
    await foreground(tester);
    final fixture = Fixture();
    addTearDown(fixture.dispose);
    final discovery = await fixture.ready(tester);
    final query = MusicSearchQuery(
      accountGeneration: discovery.accountGeneration,
      configEntryId: 'entry',
      text: 'Song',
    );
    final sub = fixture.container.listen(musicSearchProvider(query), (_, _) {});
    await tester.pump(const Duration(milliseconds: 100));
    sub.close();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 301));
    expect(fixture.api.searchReads, 0);
    fixture.dispose();
    await tester.pump();
  });
  testWidgets(
    'queue requires visible subscriber; background pauses IO, resume reads, unwatch stops timer',
    (tester) async {
      await foreground(tester);
      final fixture = Fixture();
      addTearDown(fixture.dispose);
      final discovery = await fixture.ready(tester);
      final query = MusicQueueQuery(
        accountGeneration: discovery.accountGeneration,
        configEntryId: 'entry',
        entityId: 'media_player.kitchen',
      );
      // Constructing a repository or reading discovery never fetches a queue.
      expect(fixture.api.queueReads, 0);
      final sub = fixture.container.listen(
        musicQueueProvider(query),
        (_, _) {},
      );
      await tester.pump();
      expect(fixture.api.queueReads, 1);
      await tester.pump(const Duration(seconds: 31));
      expect(fixture.api.queueReads, 2);
      _pause(tester);
      await tester.pump();
      await tester.pump(const Duration(seconds: 90));
      expect(fixture.api.queueReads, 2);
      expect(
        fixture.container.read(musicQueueProvider(query)).value?.value,
        isNull,
      );
      _resume(tester);
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1));
      expect(fixture.api.queueReads, 3);
      sub.close();
      await tester.pump();
      await tester.pump(const Duration(seconds: 90));
      expect(fixture.api.queueReads, 3);
      fixture.dispose();
      await tester.pump();
    },
  );
  testWidgets(
    'controller coalesces refresh and ignores late pre-background result on resume',
    (tester) async {
      await foreground(tester);
      await tester.pumpWidget(const SizedBox());
      var reads = 0;
      final pending = Completer<MusicQueueSummary>();
      final expected = parseMusicQueue(musicQueue(), 'media_player.kitchen');
      final controller = MusicQueueController(
        read: () async {
          reads++;
          return reads == 1 ? await pending.future : expected;
        },
        now: () => musicTime,
      );
      controller.start();
      controller.refresh();
      controller.refresh();
      expect(reads, 1);
      _pause(tester);
      await tester.pump();
      expect(controller.state.isPaused, isTrue);
      _resume(tester);
      await tester.pump();
      expect(reads, 1);
      pending.complete(expected);
      await tester.pump();
      expect(reads, 2);
      expect(controller.state.value, expected);
      controller.dispose();
      controller.refresh();
      expect(reads, 2);
    },
  );
  testWidgets(
    'controller retains prior queue with failure and original read time',
    (tester) async {
      await foreground(tester);
      await tester.pumpWidget(const SizedBox());
      var failed = false;
      final controller = MusicQueueController(
        read: () async {
          if (failed) throw TimeoutException('private');
          return parseMusicQueue(musicQueue(), 'media_player.kitchen');
        },
        now: () => musicTime,
      );
      controller.start();
      await tester.pump();
      failed = true;
      controller.refresh();
      await tester.pump();
      expect(controller.state.value, isNotNull);
      expect(controller.state.readAt, musicTime);
      expect(controller.state.failure, MusicFailure.timeout);
      expect(controller.state.isStaleAt(musicTime), isTrue);
      controller.dispose();
    },
  );
}

void _pause(WidgetTester tester) {
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
}

void _resume(WidgetTester tester) {
  if (tester.binding.lifecycleState == AppLifecycleState.paused) {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
  }
  if (tester.binding.lifecycleState == AppLifecycleState.hidden) {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
  }
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
}
