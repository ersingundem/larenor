import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/media/casting/domain/remote_playback_models.dart';
import 'package:larenor/features/media/casting/presentation/remote_playback_button.dart';
import 'package:larenor/features/media/casting/presentation/remote_playback_screen.dart';
import 'package:larenor/features/media/casting/providers/remote_playback_providers.dart';
import 'package:larenor/features/media/jellyfin/data/jellyfin_config.dart';
import 'package:larenor/features/media/jellyfin/providers/jellyfin_providers.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';

import 'remote_playback_fixture.dart';

class _Connection extends JellyfinConnection {
  @override
  Future<JellyfinConfig?> build() async => const JellyfinConfig(
    baseUrl: 'https://jellyfin.test',
    userId: userId,
    accessToken: 'first-fixture',
    deviceId: 'local-tablet',
  );
  void replace() => state = const AsyncData(
    JellyfinConfig(
      baseUrl: 'https://jellyfin.test',
      userId: userId,
      accessToken: 'replacement-fixture',
      deviceId: 'local-tablet',
    ),
  );
  // Deliberately reproduce Riverpod's retained-value reload/error state.
  void loading() =>
      // ignore: invalid_use_of_internal_member
      state = const AsyncLoading<JellyfinConfig?>().copyWithPrevious(state);
  void fail() => state = AsyncError<JellyfinConfig?>(
    StateError('fixture configuration unavailable'),
    StackTrace.current,
    // ignore: invalid_use_of_internal_member
  ).copyWithPrevious(state);
}

Future<void> _frames(WidgetTester tester) async {
  for (var i = 0; i < 4; i++) {
    await tester.pump(Duration.zero);
  }
}

class _Harness {
  final api = FakeRemoteApi();
  final visible = ValueNotifier(true);
  final currentItem = ValueNotifier(itemId);
  late ProviderContainer container;

  Future<void> mount(
    WidgetTester tester, {
    bool button = false,
    Size size = const Size(600, 1100),
    double scale = 1,
  }) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    container = ProviderContainer(
      retry: (_, _) => null,
      overrides: [
        jellyfinConnectionProvider.overrideWith(_Connection.new),
        remotePlaybackApiProvider.overrideWith((_) => api),
        remotePlaybackClockProvider.overrideWithValue(() => remoteNow),
      ],
    );
    addTearDown(container.dispose);
    addTearDown(visible.dispose);
    addTearDown(currentItem.dispose);
    await container.read(jellyfinConnectionProvider.future);
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
            builder: (context, value, _) => TickerMode(
              enabled: value,
              child: ValueListenableBuilder(
                valueListenable: currentItem,
                builder: (context, id, _) => button
                    ? CupertinoPageScaffold(
                        child: Center(child: RemotePlaybackButton(itemId: id)),
                      )
                    : RemotePlaybackScreen(itemId: id),
              ),
            ),
          ),
        ),
      ),
    );
    await _frames(tester);
  }

  AppLocalizations labels(WidgetTester tester) => AppLocalizations.of(
    tester.element(find.byType(RemotePlaybackScreen).first),
  );

  Future<void> select(WidgetTester tester) async {
    final target = find.text('Living room TV');
    await tester.ensureVisible(target);
    await tester.tap(target);
    await _frames(tester);
    await tester.pump(const Duration(milliseconds: 250));
  }

  CupertinoDialogAction playAction(WidgetTester tester) =>
      tester.widget<CupertinoDialogAction>(
        find.widgetWithText(
          CupertinoDialogAction,
          labels(tester).mediaActionPlay,
        ),
      );

  Future<void> play(WidgetTester tester) async {
    playAction(tester).onPressed!();
    await _frames(tester);
    await tester.pump(const Duration(milliseconds: 250));
    await _frames(tester);
  }

  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    container.dispose();
    await _frames(tester);
  }
}

void main() {
  testWidgets('passive navigation button does no receiver or item IO', (
    tester,
  ) async {
    final h = _Harness();
    await h.mount(tester, button: true);
    await tester.pump(const Duration(minutes: 1));
    expect(h.api.reads, 0);
    expect(h.api.itemReads, 0);
    expect(h.api.commands, isEmpty);
    await tester.tap(find.byKey(const ValueKey('media-remote-play')));
    await _frames(tester);
    await tester.pump(const Duration(milliseconds: 400));
    await _frames(tester);
    expect(find.byType(RemotePlaybackScreen), findsOneWidget);
    expect(h.api.reads, 1);
    expect(h.api.itemReads, 0);
    await h.unmount(tester);
  });

  testWidgets(
    'fresh title is read before confirmation and cancel sends nothing',
    (tester) async {
      final h = _Harness();
      await h.mount(tester);
      h.api.itemGate = Completer<void>();
      await h.select(tester);
      expect(h.api.itemReads, 1);
      expect(find.byType(CupertinoAlertDialog), findsNothing);
      expect(h.api.commands, isEmpty);
      h.api.item = playableItem.copyWith(name: 'Fresh current account title');
      h.api.itemGate!.complete();
      await _frames(tester);
      await tester.pump(const Duration(milliseconds: 250));
      expect(
        find.text('Selected title: Fresh current account title'),
        findsOneWidget,
      );
      expect(find.text('Target device: Living room TV'), findsOneWidget);
      await tester.tap(
        find.widgetWithText(
          CupertinoDialogAction,
          h.labels(tester).commonCancel,
        ),
      );
      await _frames(tester);
      await tester.pumpAndSettle();
      expect(h.api.commands, isEmpty);
      expect(h.api.itemReads, 1);
      expect(find.byType(CupertinoAlertDialog), findsNothing);
      await h.unmount(tester);
    },
  );

  testWidgets('duplicate target and approval callbacks dispatch only once', (
    tester,
  ) async {
    final h = _Harness();
    await h.mount(tester);
    h.api.itemGate = Completer<void>();
    final choose = tester
        .widget<CupertinoButton>(
          find.ancestor(
            of: find.text('Living room TV'),
            matching: find.byType(CupertinoButton),
          ),
        )
        .onPressed!;
    choose();
    choose();
    await _frames(tester);
    expect(h.api.itemReads, 1);
    h.api.itemGate!.complete();
    await _frames(tester);
    await tester.pump(const Duration(milliseconds: 250));
    final approve = h.playAction(tester).onPressed!;
    h.api.playGate = Completer<void>();
    approve();
    approve();
    await _frames(tester);
    await tester.pump(const Duration(milliseconds: 250));
    expect(h.api.commands, hasLength(1));
    expect(h.api.itemReads, 2);
    expect(h.api.reads, 2);
    choose();
    await _frames(tester);
    expect(h.api.commands, hasLength(1));
    h.api.playGate!.complete();
    await _frames(tester);
    expect(find.text(h.labels(tester).mediaRemoteAccepted), findsOneWidget);
    await h.unmount(tester);
  });

  for (final invalidation in ['account', 'background', 'item']) {
    testWidgets('$invalidation change invalidates an open approval callback', (
      tester,
    ) async {
      final h = _Harness();
      await h.mount(tester);
      await h.select(tester);
      final approve = h.playAction(tester).onPressed!;
      switch (invalidation) {
        case 'account':
          (h.container.read(jellyfinConnectionProvider.notifier) as _Connection)
              .replace();
        case 'background':
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.inactive,
          );
        case 'item':
          h.currentItem.value = otherItemId;
      }
      await _frames(tester);
      expect(find.byType(CupertinoAlertDialog), findsNothing);
      approve();
      await _frames(tester);
      if (invalidation == 'background') {
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await _frames(tester);
        approve();
        await _frames(tester);
      }
      expect(h.api.commands, isEmpty);
      expect(tester.takeException(), isNull);
      await h.unmount(tester);
    });
  }

  for (final invalidation in ['account', 'background', 'item', 'offstage']) {
    testWidgets(
      '$invalidation during preparation suppresses late confirmation',
      (tester) async {
        final h = _Harness();
        await h.mount(tester);
        h.api.itemGate = Completer<void>();
        await h.select(tester);
        switch (invalidation) {
          case 'account':
            (h.container.read(
              jellyfinConnectionProvider.notifier,
            ) as _Connection).replace();
          case 'background':
            tester.binding.handleAppLifecycleStateChanged(
              AppLifecycleState.inactive,
            );
          case 'item':
            h.currentItem.value = otherItemId;
          case 'offstage':
            h.visible.value = false;
        }
        await _frames(tester);
        h.api.itemGate!.complete();
        await _frames(tester);
        expect(find.byType(CupertinoAlertDialog), findsNothing);
        expect(h.api.commands, isEmpty);
        if (invalidation == 'offstage') {
          h.visible.value = true;
          await _frames(tester);
        }
        if (invalidation == 'background') {
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.resumed,
          );
          await _frames(tester);
        }
        expect(find.byType(CupertinoAlertDialog), findsNothing);
        expect(tester.takeException(), isNull);
        await h.unmount(tester);
      },
    );
  }

  testWidgets(
    'discovery failure is visible and does not masquerade as empty clients',
    (tester) async {
      final h = _Harness();
      h.api.targetError = TimeoutException('fixture discovery');
      await h.mount(tester);
      final l10n = h.labels(tester);
      expect(
        find.text(
          remotePlaybackFailureLabel(l10n, RemotePlaybackFailure.timeout),
        ),
        findsOneWidget,
      );
      expect(find.text(l10n.mediaRemoteEmpty), findsNothing);
      expect(find.text(l10n.mediaRemoteUnconfirmed), findsNothing);
      expect(find.text('Living room TV'), findsNothing);
      await tester.pump(const Duration(minutes: 1));
      expect(h.api.reads, 1);
      expect(h.api.commands, isEmpty);
      h.api.targetError = null;
      await tester.tap(find.text(l10n.commonRefresh));
      await _frames(tester);
      expect(h.api.reads, 2);
      expect(find.text('Living room TV'), findsOneWidget);
      await h.unmount(tester);
    },
  );

  testWidgets(
    'retained configuration during reload and error never shows old targets',
    (tester) async {
      final h = _Harness();
      await h.mount(tester);
      expect(find.text('Living room TV'), findsOneWidget);
      final connection =
          h.container.read(jellyfinConnectionProvider.notifier) as _Connection;
      connection.loading();
      await _frames(tester);
      expect(find.text('Living room TV'), findsNothing);
      expect(
        find.text(h.labels(tester).mediaRemoteAccountChanged),
        findsOneWidget,
      );
      connection.fail();
      await _frames(tester);
      await tester.pump(const Duration(minutes: 1));
      expect(find.text('Living room TV'), findsNothing);
      expect(h.api.reads, 1);
      expect(h.api.commands, isEmpty);
      await h.unmount(tester);
    },
  );

  testWidgets(
    'confirmed item losing playback access shows failure without POST',
    (tester) async {
      final h = _Harness();
      await h.mount(tester);
      await h.select(tester);
      h.api.item = playableItem.copyWith(playAccess: 'None');
      await h.play(tester);
      expect(h.api.itemReads, 2);
      expect(h.api.commands, isEmpty);
      expect(
        find.text(h.labels(tester).mediaRemoteUnsupportedItem),
        findsOneWidget,
      );
      expect(find.text(h.labels(tester).mediaRemoteAccepted), findsNothing);
      expect(find.text(h.labels(tester).mediaRemoteUnconfirmed), findsNothing);
      await h.unmount(tester);
    },
  );

  testWidgets('preflight timeout is distinct from uncertain command timeout', (
    tester,
  ) async {
    final h = _Harness();
    await h.mount(tester);
    final l10n = h.labels(tester);
    h.api.itemError = TimeoutException('fixture preflight');
    await h.select(tester);
    expect(h.api.commands, isEmpty);
    expect(
      find.text(
        remotePlaybackFailureLabel(l10n, RemotePlaybackFailure.timeout),
      ),
      findsOneWidget,
    );
    expect(find.text(l10n.mediaRemoteUnconfirmed), findsNothing);
    h.api.itemError = null;
    h.api.playError = TimeoutException('fixture command');
    await h.select(tester);
    await h.play(tester);
    expect(h.api.commands, hasLength(1));
    expect(find.text(l10n.mediaRemoteUnconfirmed), findsOneWidget);
    expect(find.text(l10n.mediaRemoteAccepted), findsNothing);
    expect(find.text(l10n.mediaRemoteObserved), findsNothing);
    await tester.pump(const Duration(minutes: 1));
    expect(h.api.commands, hasLength(1));
    await h.unmount(tester);
  });

  testWidgets(
    'receipt is shown only for the matching item and observed separately',
    (tester) async {
      final h = _Harness();
      await h.mount(tester);
      final l10n = h.labels(tester);
      await h.select(tester);
      await h.play(tester);
      expect(find.text(l10n.mediaRemoteAccepted), findsOneWidget);
      expect(find.text(l10n.mediaRemoteObserved), findsNothing);
      h.api.targets = [target(nowPlaying: itemId)];
      await tester.pump(const Duration(seconds: 1));
      await _frames(tester);
      expect(find.text(l10n.mediaRemoteObserved), findsOneWidget);
      h.currentItem.value = otherItemId;
      await _frames(tester);
      expect(find.text(l10n.mediaRemoteObserved), findsNothing);
      expect(find.text(l10n.mediaRemoteAccepted), findsNothing);
      expect(h.api.commands, hasLength(1));
      await h.unmount(tester);
    },
  );

  testWidgets(
    'hidden screen stops observation and resume discovers without replay',
    (tester) async {
      final h = _Harness();
      await h.mount(tester);
      await h.select(tester);
      await h.play(tester);
      expect(h.api.reads, 2);
      h.visible.value = false;
      await _frames(tester);
      await tester.pump(const Duration(minutes: 5));
      expect(h.api.reads, 2);
      h.visible.value = true;
      await _frames(tester);
      expect(h.api.reads, 3);
      expect(h.api.commands, hasLength(1));
      await tester.pump(const Duration(minutes: 5));
      expect(h.api.reads, 3);
      await h.unmount(tester);
    },
  );

  for (final device in [
    (name: 'phone', size: const Size(320, 1000), scale: 2.0),
    (name: 'tablet', size: const Size(1280, 1000), scale: 1.6),
  ]) {
    testWidgets('lazy targets and approval fit ${device.name} at large text', (
      tester,
    ) async {
      final h = _Harness();
      h.api.targets = List.generate(
        200,
        (index) => parseRemotePlaybackTargets([
          {
            ...targetJson(id: 'session-$index', device: 'device-$index'),
            'DeviceName': index == 0
                ? 'Living room TV'
                : 'Private television $index',
          },
        ]).single,
      );
      h.api.item = playableItem.copyWith(
        name: 'A long current-account movie title that wraps without hiding approval',
      );
      await h.mount(tester, size: device.size, scale: device.scale);
      expect(find.text('Private television 199'), findsNothing);
      expect(
        find.textContaining('Private television').evaluate().length,
        lessThan(30),
      );
      await h.select(tester);
      expect(find.byType(CupertinoAlertDialog), findsOneWidget);
      expect(tester.takeException(), isNull);
      final cancel = find.widgetWithText(
        CupertinoDialogAction,
        h.labels(tester).commonCancel,
      );
      await tester.ensureVisible(cancel);
      await tester.tap(cancel);
      await _frames(tester);
      await tester.pump(const Duration(milliseconds: 250));
      expect(h.api.commands, isEmpty);
      expect(tester.takeException(), isNull);
      await h.unmount(tester);
    });
  }
}
