import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/auth/data/ha_connection_config.dart';
import 'package:larenor/features/auth/providers/auth_providers.dart';
import 'package:larenor/features/media/ha_playback/domain/ha_media_inventory.dart';
import 'package:larenor/features/media/ha_playback/domain/ha_playback_models.dart';
import 'package:larenor/features/media/ha_playback/presentation/ha_playback_screen.dart';
import 'package:larenor/features/media/ha_playback/providers/ha_playback_providers.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';

import 'ha_playback_fixture.dart';

class _Connection extends ConnectionConfig {
  @override
  Future<HaConnectionConfig?> build() async => const HaConnectionConfig(
    baseUrl: 'https://ha.invalid',
    token: 'first-fixture',
  );
  void replace() => state = const AsyncData(
    HaConnectionConfig(baseUrl: 'https://ha.invalid', token: 'second-fixture'),
  );
  void loading() => state = const AsyncLoading<HaConnectionConfig?>()
      // ignore: invalid_use_of_internal_member
      .copyWithPrevious(state);
  void fail() => state =
      AsyncError<HaConnectionConfig?>(
        StateError('private fixture'),
        StackTrace.current,
      )
      // ignore: invalid_use_of_internal_member
      .copyWithPrevious(state);
}

Future<void> frames(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(Duration.zero);
  }
}

class _Harness {
  final api = FakeHaPlaybackApi(), other = FakeHaPlaybackApi();
  final visible = ValueNotifier(true);
  late ProviderContainer container;
  Future<void> mount(
    WidgetTester tester, {
    Size size = const Size(650, 1100),
    double scale = 1,
  }) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    container = ProviderContainer(
      retry: (_, _) => null,
      overrides: [
        connectionConfigProvider.overrideWith(_Connection.new),
        haPlaybackApiProvider.overrideWith((ref) {
          final config = ref.watch(connectionConfigProvider);
          if (config.isLoading || config.hasError) return null;
          return config.value?.token == 'first-fixture' ? api : other;
        }),
        haPlaybackClockProvider.overrideWithValue(() => playbackNow),
      ],
    );
    addTearDown(container.dispose);
    addTearDown(visible.dispose);
    addTearDown(api.dispose);
    addTearDown(other.dispose);
    await container.read(connectionConfigProvider.future);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: CupertinoApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
          home: ValueListenableBuilder(
            valueListenable: visible,
            builder: (context, value, _) =>
                TickerMode(enabled: value, child: const HaPlaybackScreen()),
          ),
        ),
      ),
    );
    await frames(tester);
  }

  AppLocalizations labels(WidgetTester tester) =>
      AppLocalizations.of(tester.element(find.byType(HaPlaybackScreen)));
  _Connection get connection =>
      container.read(connectionConfigProvider.notifier) as _Connection;
  Future<void> button(WidgetTester tester, Finder finder) async {
    if (finder.evaluate().isEmpty) {
      await tester.scrollUntilVisible(
        finder,
        250,
        scrollable: find.byType(Scrollable).first,
      );
    }
    await tester.ensureVisible(finder);
    tester.widget<CupertinoButton>(finder).onPressed!();
    await frames(tester);
  }

  Future<void> source(WidgetTester tester) =>
      button(tester, find.byKey(const ValueKey('ha-media-source-0')));
  Future<void> target(WidgetTester tester) => button(
    tester,
    find.byKey(const ValueKey('ha-media-target-media_player.living')),
  );
  CupertinoDialogAction confirm(WidgetTester tester) => tester.widget(
    find.widgetWithText(CupertinoDialogAction, labels(tester).mediaActionPlay),
  );
  Future<void> finishDialog(WidgetTester tester) async {
    await frames(tester);
    await tester.pump(const Duration(milliseconds: 400));
    await frames(tester);
  }

  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    container.dispose();
    await frames(tester);
  }
}

void main() {
  testWidgets(
    'source to target named confirmation cancel sends zero and double confirm sends once',
    (tester) async {
      final h = _Harness();
      await h.mount(tester);
      await h.source(tester);
      await h.target(tester);
      await h.finishDialog(tester);
      expect(
        find.text('${h.labels(tester).mediaRemoteItem}: Test audio'),
        findsOneWidget,
      );
      expect(
        find.text('${h.labels(tester).mediaRemoteDevice}: Living room'),
        findsOneWidget,
      );
      expect(h.api.commands, isEmpty);
      tester
          .widget<CupertinoDialogAction>(
            find.widgetWithText(
              CupertinoDialogAction,
              h.labels(tester).commonCancel,
            ),
          )
          .onPressed!();
      await h.finishDialog(tester);
      expect(h.api.commands, isEmpty);
      await h.target(tester);
      await h.finishDialog(tester);
      final action = h.confirm(tester).onPressed!;
      action();
      action();
      await h.finishDialog(tester);
      expect(h.api.commands, hasLength(1));
      expect(find.text(h.labels(tester).haMediaAccepted), findsOneWidget);
      final text = tester
          .widgetList<Text>(find.byType(Text))
          .map((x) => x.data ?? '')
          .join(' ');
      expect(text, isNot(contains('media-source://')));
      expect(text, isNot(contains('fixture')));
      await h.unmount(tester);
    },
  );
  testWidgets('folder ancestry back and root navigate by fresh browse only', (
    tester,
  ) async {
    final h = _Harness();
    const id = 'media-source://media_source';
    h.api.pages['media-source://'] = parseHaMediaBrowse(
      browseRaw(
        children: [
          browseNode(
            id: id,
            title: 'Local media',
            type: 'directory',
            play: false,
            expand: true,
          ),
        ],
      ),
      playbackNow,
    );
    h.api.pages[id] = parseHaMediaBrowse(browseRaw(parent: id), playbackNow);
    await h.mount(tester);
    await h.source(tester);
    expect(h.api.browseIds.last, id);
    await h.button(
      tester,
      find.widgetWithText(CupertinoButton, h.labels(tester).commonBack),
    );
    expect(h.api.browseIds.last, 'media-source://');
    await h.source(tester);
    await h.button(
      tester,
      find.widgetWithText(CupertinoButton, h.labels(tester).haMediaRoot),
    );
    expect(h.api.browseIds.last, isNull);
    expect(h.api.commands, isEmpty);
    await h.unmount(tester);
  });
  testWidgets(
    'source changed after visible confirmation sends nothing and shows safe failure',
    (tester) async {
      final h = _Harness();
      await h.mount(tester);
      await h.source(tester);
      await h.target(tester);
      await h.finishDialog(tester);
      h.api.pages['media-source://'] = parseHaMediaBrowse(
        browseRaw(children: []),
        playbackNow,
      );
      h.confirm(tester).onPressed!();
      await h.finishDialog(tester);
      expect(h.api.commands, isEmpty);
      expect(find.text(h.labels(tester).haMediaSourceChanged), findsOneWidget);
      await h.unmount(tester);
    },
  );
  for (final change in [
    'account',
    'loading',
    'error',
    'background',
    'hidden',
  ]) {
    testWidgets('$change closes approval and old callback cannot play', (
      tester,
    ) async {
      final h = _Harness();
      await h.mount(tester);
      await h.source(tester);
      await h.target(tester);
      await h.finishDialog(tester);
      final oldAction = h.confirm(tester).onPressed!;
      switch (change) {
        case 'account':
          h.connection.replace();
        case 'loading':
          h.connection.loading();
        case 'error':
          h.connection.fail();
        case 'background':
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.inactive,
          );
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.hidden,
          );
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.paused,
          );
        case 'hidden':
          h.visible.value = false;
      }
      await frames(tester);
      oldAction();
      await h.finishDialog(tester);
      expect(find.byType(CupertinoAlertDialog), findsNothing);
      expect(h.api.commands, isEmpty);
      expect(h.other.commands, isEmpty);
      final reads = h.api.inventoryReads;
      await tester.pump(const Duration(minutes: 1));
      expect(h.api.inventoryReads, reads);
      await h.unmount(tester);
      if (change == 'background') {
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.inactive,
        );
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
      }
    });
  }
  testWidgets(
    'pending initial old account read cannot expose replacement targets',
    (tester) async {
      final h = _Harness();
      final gate = Completer<void>();
      h.api.inventoryGate = () => gate.future;
      await h.mount(tester);
      h.connection.replace();
      await frames(tester);
      gate.complete();
      await frames(tester);
      expect(find.byKey(const ValueKey('ha-media-source-0')), findsNothing);
      expect(h.other.inventoryReads, 0);
      expect(h.api.commands, isEmpty);
      await h.unmount(tester);
    },
  );
  testWidgets(
    'hidden during dispatch preflight closes the send lease immediately',
    (tester) async {
      final h = _Harness();
      await h.mount(tester);
      await h.source(tester);
      await h.target(tester);
      await h.finishDialog(tester);
      final gate = Completer<void>();
      h.api.browseGate = () => gate.future;
      h.confirm(tester).onPressed!();
      await frames(tester);
      h.visible.value = false;
      await tester.pump();
      gate.complete();
      await frames(tester);
      expect(h.api.commands, isEmpty);
      await h.unmount(tester);
    },
  );
  testWidgets(
    '5000 source nodes are lazy and remain static rather than player previews',
    (tester) async {
      final h = _Harness();
      h.api.pages['media-source://'] = parseHaMediaBrowse(
        browseRaw(
          children: List.generate(
            5000,
            (i) => browseNode(
              id: 'media-source://media_source/local/$i.mp3',
              title: 'Track $i',
            ),
          ),
        ),
        playbackNow,
      );
      await h.mount(tester);
      expect(find.byKey(const ValueKey('ha-media-source-4999')), findsNothing);
      expect(find.byType(CupertinoButton).evaluate().length, lessThan(40));
      expect(h.api.commands, isEmpty);
      expect(h.api.inventoryReads, 1);
      await h.unmount(tester);
    },
  );
  testWidgets(
    '5000 targets render lazily without mutating on selection preview',
    (tester) async {
      final h = _Harness();
      h.api.currentInventory = parseHaMediaInventory(
        states: List.generate(
          5000,
          (i) => stateRaw(id: 'media_player.room_$i'),
        ),
        services: mediaServices,
        registry: List.generate(
          5000,
          (i) => registryRaw(id: 'media_player.room_$i', registry: 'reg$i'),
        ),
        readAt: playbackNow,
      );
      await h.mount(tester);
      await h.source(tester);
      expect(
        find.byKey(const ValueKey('ha-media-target-media_player.room_4999')),
        findsNothing,
      );
      expect(find.byType(CupertinoButton).evaluate().length, lessThan(40));
      expect(h.api.commands, isEmpty);
      await h.unmount(tester);
    },
  );
  for (final video in [false, true]) {
    testWidgets('Apple TV source route accurately restricts video ($video)', (
      tester,
    ) async {
      final h = _Harness();
      h.api.currentInventory = inventory(
        state: stateRaw(deviceClass: 'tv'),
        registry: registryRaw(platform: 'apple_tv'),
      );
      h.api.pages['media-source://'] = parseHaMediaBrowse(
        browseRaw(
          children: [browseNode(type: video ? 'video/mp4' : 'audio/mpeg')],
        ),
        playbackNow,
      );
      await h.mount(tester);
      await h.source(tester);
      final target = find.byKey(
        const ValueKey('ha-media-target-media_player.living'),
      );
      if (target.evaluate().isEmpty) {
        await tester.scrollUntilVisible(
          target,
          200,
          scrollable: find.byType(Scrollable).first,
        );
      }
      expect(
        tester.widget<CupertinoButton>(target).onPressed,
        video ? isNull : isNotNull,
      );
      expect(h.api.commands, isEmpty);
      await h.unmount(tester);
    });
  }
  for (final size in [const Size(320, 900), const Size(1280, 900)]) {
    testWidgets(
      'source/target/confirmation fits ${size.width}px at large text',
      (tester) async {
        final h = _Harness();
        await h.mount(tester, size: size, scale: size.width == 320 ? 2 : 1.6);
        await h.source(tester);
        await h.target(tester);
        await h.finishDialog(tester);
        expect(tester.takeException(), isNull);
        expect(find.byType(CupertinoAlertDialog), findsOneWidget);
        expect(h.api.commands, isEmpty);
        await h.unmount(tester);
      },
    );
  }
  testWidgets(
    'failed browse is not shown as known empty and retry errors stay sanitized',
    (tester) async {
      final h = _Harness();
      h.api.browseError = StateError('private-token-url');
      await h.mount(tester);
      expect(find.text(h.labels(tester).haMediaEmpty), findsNothing);
      expect(find.textContaining('private-token'), findsNothing);
      expect(h.api.commands, isEmpty);
      await h.unmount(tester);
    },
  );
}
