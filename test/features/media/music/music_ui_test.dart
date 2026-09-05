// Reproduce Riverpod retained loading/error values in the real music UI.
// ignore_for_file: invalid_use_of_internal_member
import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/auth/data/ha_connection_config.dart';
import 'package:larenor/features/auth/providers/auth_providers.dart';
import 'package:larenor/features/ha_client/data/ha_api_exception.dart';
import 'package:larenor/features/media/ha_playback/data/ha_playback_api.dart';
import 'package:larenor/features/media/ha_playback/domain/ha_media_inventory.dart';
import 'package:larenor/features/media/ha_playback/domain/ha_playback_models.dart';
import 'package:larenor/features/media/ha_playback/providers/ha_playback_providers.dart';
import 'package:larenor/features/media/music/domain/music_models.dart';
import 'package:larenor/features/media/music/presentation/music_center_screen.dart';
import 'package:larenor/features/media/music/presentation/music_playback_screen.dart';
import 'package:larenor/features/media/music/providers/music_playback_providers.dart';
import 'package:larenor/features/media/music/providers/music_providers.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';

import 'music_fixtures.dart';
import 'music_playback_test.dart' show PlaybackFixture;

const _config = HaConnectionConfig(
  baseUrl: 'http://fixture.invalid',
  token: 'fixture',
);

class _Connection extends ConnectionConfig {
  @override
  Future<HaConnectionConfig?> build() async => _config;
  void loading() =>
      state = const AsyncLoading<HaConnectionConfig?>().copyWithPrevious(state);
  void denied() => state = AsyncError<HaConnectionConfig?>(
    StateError('private'),
    StackTrace.current,
  ).copyWithPrevious(state);
  void change() => state = const AsyncData(
    HaConnectionConfig(baseUrl: 'http://new.invalid', token: 'new-fixture'),
  );
}

class _Reads extends FakeMusicApi {
  bool fullPage = false;
  final queries = <MusicLibraryQuery>[];
  @override
  Future<Object?> library(
    MusicLibraryQuery query, {
    required bool Function() isCurrent,
  }) async {
    await super.library(query, isCurrent: isCurrent);
    queries.add(query);
    return {
      ...musicLibrary(query),
      'items': [
        for (var i = 0; i < (fullPage ? query.limit : 3); i++)
          {
            ...musicItem(type: query.type, name: 'Song ${query.offset + i}'),
            'uri': 'library://${query.type.name}/${query.offset + i}',
          },
      ],
    };
  }
}

class _Inventory extends HaPlaybackApi {
  _Inventory(this.fixture);
  final PlaybackFixture fixture;
  @override
  Future<HaMediaInventory> getInventory() async {
    fixture.inventoryReads++;
    if (fixture.inventoryGate != null) await fixture.inventoryGate!.future;
    return fixture.inventory();
  }

  @override
  Future<HaMediaBrowsePage> browse(String? sourceId) async =>
      throw StateError('not used');
  @override
  Future<void> play({
    required String entityId,
    required HaMediaNode source,
    required bool Function() isCurrent,
  }) async => throw StateError('wrong playback path');
}

class _Harness {
  final fixture = PlaybackFixture();
  final reads = _Reads();
  final visible = ValueNotifier(true);
  final connection = _Connection();
  late ProviderContainer container;
  Future<void> mount(
    WidgetTester tester, {
    Size size = const Size(800, 1100),
    double scale = 1,
    Brightness brightness = Brightness.light,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(tester.view.reset);
    container = ProviderContainer(
      overrides: [
        connectionConfigProvider.overrideWith(() => connection),
        musicAssistantApiProvider.overrideWithValue(reads),
        musicPlaybackApiProvider.overrideWithValue(fixture.api),
        haPlaybackApiProvider.overrideWithValue(_Inventory(fixture)),
        musicClockProvider.overrideWithValue(() => fixture.now),
      ],
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      container.dispose();
      fixture.dispose();
      visible.dispose();
      await tester.pump();
    });
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: CupertinoApp(
          locale: const Locale('en'),
          theme: CupertinoThemeData(brightness: brightness),
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
                TickerMode(enabled: value, child: const MusicCenterScreen()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> library(WidgetTester tester) async {
    await tester.tap(find.text('Library'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Choose a Music Assistant connection').first);
    await tester.pumpAndSettle();
    await tester.tap(
      find.widgetWithText(CupertinoActionSheetAction, 'Home music'),
    );
    await tester.pumpAndSettle();
  }

  Future<void> playback(WidgetTester tester) async {
    await library(tester);
    await tester.scrollUntilVisible(find.text('Song 0'), 300, maxScrolls: 30);
    await tester.tap(find.text('Song 0'));
    await tester.pumpAndSettle();
    expect(find.byType(MusicPlaybackScreen), findsOneWidget);
  }

  Future<void> confirmDialog(WidgetTester tester) async {
    await playback(tester);
    await tester.tap(find.text('Kitchen').last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(CupertinoAlertDialog), findsOneWidget);
  }
}

void main() {
  testWidgets(
    'open music is read-only, MA absence is distinct from failed discovery',
    (tester) async {
      final h = _Harness();
      h.reads.entries = [];
      await h.mount(tester);
      expect(h.fixture.api.calls, 0);
      expect(h.reads.libraryReads, 0);
      await tester.tap(find.text('Library'));
      await tester.pumpAndSettle();
      expect(
        find.text('Music Assistant is not connected to Home Assistant.'),
        findsWidgets,
      );
      h.reads.entriesError = HaApiException('secret', code: 'unauthorized');
      h.container.invalidate(musicDiscoveryProvider);
      await tester.pumpAndSettle();
      expect(
        find.text('Music Assistant is not connected to Home Assistant.'),
        findsNothing,
      );
      expect(
        find.text(
          'Some music information could not be read. Available sources are shown below.',
        ),
        findsOneWidget,
      );
      expect(find.textContaining('secret'), findsNothing);
      expect(h.fixture.api.calls, 0);
    },
  );
  for (final brightness in Brightness.values) {
    testWidgets(
      'selected music tab and type maintain contrast in ${brightness.name}',
      (tester) async {
        final h = _Harness();
        await h.mount(tester, brightness: brightness);
        Color? colorOf(String text) {
          final rich = tester.widget<RichText>(
            find.descendant(
              of: find.text(text).first,
              matching: find.byType(RichText),
            ),
          );
          return (rich.text as TextSpan).style?.color;
        }

        expect(colorOf('Outputs'), CupertinoColors.white);
        await h.library(tester);
        expect(colorOf('Library'), CupertinoColors.white);
        expect(colorOf('Tracks'), CupertinoColors.white);
      },
    );
  }
  for (final action in ['loading', 'error', 'account']) {
    testWidgets(
      '$action hides old library and prevents retained item callback',
      (tester) async {
        final h = _Harness();
        await h.mount(tester);
        await h.library(tester);
        final button = tester.widget<CupertinoButton>(
          find
              .ancestor(
                of: find.text('Song 0'),
                matching: find.byType(CupertinoButton),
              )
              .first,
        );
        switch (action) {
          case 'loading':
            h.connection.loading();
          case 'error':
            h.connection.denied();
          case 'account':
            h.connection.change();
        }
        await tester.pumpAndSettle();
        expect(find.text('Song 0'), findsNothing);
        button.onPressed!();
        await tester.pumpAndSettle();
        expect(find.byType(MusicPlaybackScreen), findsNothing);
        expect(h.fixture.api.calls, 0);
      },
    );
  }
  testWidgets(
    'library paging is explicit, lazy, bounded, and resets for media type',
    (tester) async {
      final h = _Harness();
      h.reads.fullPage = true;
      await h.mount(tester);
      await h.library(tester);
      expect(h.reads.queries.single.limit, 25);
      expect(find.text('Song 24'), findsNothing);
      await tester.scrollUntilVisible(
        find.text('Next page'),
        400,
        maxScrolls: 30,
      );
      await tester.tap(find.text('Next page'));
      await tester.pumpAndSettle();
      expect(h.reads.queries.last.offset, 25);
      await tester.scrollUntilVisible(
        find.text('Albums'),
        -400,
        maxScrolls: 30,
      );
      await tester.tap(find.text('Albums'));
      await tester.pumpAndSettle();
      expect(h.reads.queries.last.offset, 0);
      expect(h.reads.queries.last.type, MusicMediaType.album);
      expect(h.fixture.api.calls, 0);
    },
  );
  testWidgets(
    'search sends only submitted query and refuses stale retained submit callback',
    (tester) async {
      final h = _Harness();
      await h.mount(tester);
      await h.library(tester);
      await tester.tap(find.text('Search music').first);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('music-search-field')),
        'Song',
      );
      await tester.pump(const Duration(seconds: 1));
      expect(h.reads.searchReads, 0);
      final button = find.widgetWithText(CupertinoButton, 'Search music').last;
      final callback = tester.widget<CupertinoButton>(button).onPressed!;
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(h.reads.searchReads, 1);
      h.connection.change();
      await tester.pumpAndSettle();
      callback();
      await tester.pumpAndSettle();
      expect(h.reads.searchReads, 1);
    },
  );
  testWidgets('queue overview polls only its visible selected output', (
    tester,
  ) async {
    final h = _Harness();
    await h.mount(tester);
    await h.library(tester);
    await tester.tap(find.text('Queue overview'));
    await tester.pumpAndSettle();
    expect(h.reads.queueReads, 0);
    await tester.tap(find.text('Choose a Music Assistant output'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.widgetWithText(CupertinoActionSheetAction, 'Kitchen'),
    );
    await tester.pumpAndSettle();
    expect(h.reads.queueReads, 1);
    await tester.pump(const Duration(seconds: 31));
    await tester.pump();
    expect(h.reads.queueReads, 2);
    h.visible.value = false;
    await tester.pump();
    await tester.pump(const Duration(seconds: 90));
    expect(h.reads.queueReads, 2);
    h.visible.value = true;
    await tester.pumpAndSettle();
    // Hidden routes clear the selected output and require a new explicit choice.
    expect(h.reads.queueReads, 2);
    expect(h.fixture.api.calls, 0);
  });
  testWidgets(
    'Refresh reads the selected queue immediately without waiting for polling',
    (tester) async {
      final h = _Harness();
      await h.mount(tester);
      await h.library(tester);
      await tester.tap(find.text('Queue overview'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Choose a Music Assistant output'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.widgetWithText(CupertinoActionSheetAction, 'Kitchen'),
      );
      await tester.pumpAndSettle();
      expect(h.reads.queueReads, 1);
      await tester.tap(find.text('Refresh'));
      await tester.pumpAndSettle();
      expect(h.reads.queueReads, 2);
      expect(h.fixture.api.calls, 0);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(milliseconds: 1));
      await tester.pump(const Duration(milliseconds: 1));
    },
  );
  testWidgets(
    'parent hidden route preserves account generation in playback child; cancel sends zero',
    (tester) async {
      final h = _Harness();
      await h.mount(tester);
      await h.confirmDialog(tester);
      expect(find.text('Song 0'), findsWidgets);
      expect(find.text('Kitchen'), findsWidgets);
      expect(h.fixture.api.calls, 0);
      await tester.tap(find.widgetWithText(CupertinoDialogAction, 'Cancel'));
      await tester.pumpAndSettle();
      expect(h.fixture.api.calls, 0);
      expect(find.byType(MusicPlaybackScreen), findsOneWidget);
    },
  );
  testWidgets(
    'background closes confirmation and its old callback cannot send after resume',
    (tester) async {
      final h = _Harness();
      await h.mount(tester);
      await h.confirmDialog(tester);
      final confirm = tester
          .widget<CupertinoDialogAction>(
            find.widgetWithText(CupertinoDialogAction, 'Play now'),
          )
          .onPressed!;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(find.byType(CupertinoAlertDialog), findsNothing);
      confirm();
      await tester.pumpAndSettle();
      expect(h.fixture.api.calls, 0);
    },
  );
  testWidgets(
    'background during preflight ignores delayed catalog and cannot open old confirmation',
    (tester) async {
      final h = _Harness();
      await h.mount(tester);
      await h.playback(tester);
      final page = tester.widget<MusicPlaybackScreen>(
        find.byType(MusicPlaybackScreen),
      );
      final query = page.selection.libraryQuery!;
      h.reads.libraryGate = Completer<Object?>();
      await tester.tap(find.text('Kitchen').last);
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      h.reads.libraryGate!.complete(musicLibrary(query));
      await tester.pumpAndSettle();
      expect(find.byType(CupertinoAlertDialog), findsNothing);
      expect(h.fixture.api.calls, 0);
    },
  );
  testWidgets(
    'confirmed named catalog source sends once despite retained double callback',
    (tester) async {
      final h = _Harness();
      await h.mount(tester);
      await h.confirmDialog(tester);
      final button = tester.widget<CupertinoDialogAction>(
        find.widgetWithText(CupertinoDialogAction, 'Play now'),
      );
      button.onPressed!();
      button.onPressed!();
      await tester.pumpAndSettle();
      expect(h.fixture.api.calls, 1);
      expect(h.fixture.api.writes, 1);
      expect(
        find.text(
          'The playback result is uncertain. Check the output before sending another request.',
        ),
        findsWidgets,
      );
    },
  );
  testWidgets(
    'account change during named confirmation closes dialog and blocks old callback',
    (tester) async {
      final h = _Harness();
      await h.mount(tester);
      await h.confirmDialog(tester);
      final confirm = tester
          .widget<CupertinoDialogAction>(
            find.widgetWithText(CupertinoDialogAction, 'Play now'),
          )
          .onPressed!;
      h.connection.change();
      await tester.pumpAndSettle();
      expect(find.byType(CupertinoAlertDialog), findsNothing);
      confirm();
      await tester.pumpAndSettle();
      expect(h.fixture.api.calls, 0);
    },
  );
  testWidgets(
    'mutation timeout is localized uncertain outcome without private error or retry',
    (tester) async {
      final h = _Harness();
      h.fixture.api.error = TimeoutException('private-token');
      await h.mount(tester);
      await h.confirmDialog(tester);
      await tester.tap(find.widgetWithText(CupertinoDialogAction, 'Play now'));
      await tester.pumpAndSettle();
      expect(h.fixture.api.calls, 1);
      expect(
        find.text(
          'The playback result is uncertain. Check the output before sending another request.',
        ),
        findsWidgets,
      );
      expect(find.textContaining('private-token'), findsNothing);
      await tester.pump(const Duration(minutes: 1));
      expect(h.fixture.api.calls, 1);
    },
  );
  for (final size in [const Size(320, 800), const Size(1200, 1100)]) {
    testWidgets('music layouts fit ${size.width} width with 2x text', (
      tester,
    ) async {
      final h = _Harness();
      await h.mount(tester, size: size, scale: 2);
      expect(tester.takeException(), isNull);
      await h.library(tester);
      expect(tester.takeException(), isNull);
      await tester.scrollUntilVisible(find.text('Song 0'), 300, maxScrolls: 30);
      await tester.tap(find.text('Song 0'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.scrollUntilVisible(
        find.text('Kitchen'),
        300,
        maxScrolls: 30,
      );
      await tester.tap(find.text('Kitchen'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(tester.takeException(), isNull);
    });
  }
}
