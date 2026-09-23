import 'dart:convert' show jsonDecode;
import 'dart:async';
import 'dart:ui' show Tristate;

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/server/music_manager/presentation/server_music_manager_screen.dart';
import 'package:larenor/features/media/music/domain/music_models.dart';
import 'package:larenor/features/server/providers/server_providers.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'server_music_manager_test_support.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<MusicManagerFixture> mount(
    WidgetTester tester, {
    required String locale,
    required double width,
  }) async {
    final fixture = MusicManagerFixture();
    await fixture.account.initialize();
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = Size(width, 1000);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          serverAccountControllerProvider.overrideWithValue(fixture.account),
        ],
        child: CupertinoApp(
          locale: Locale(locale),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
          home: const ServerMusicManagerScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return fixture;
  }

  for (final locale in ['en', 'tr']) {
    for (final width in [600.0, 1200.0]) {
      testWidgets('$locale manager fits $width tablet/DeX at 2x', (
        tester,
      ) async {
        final semantics = tester.ensureSemantics();
        final fixture = await mount(tester, locale: locale, width: width);
        addTearDown(() {
          fixture.account.dispose();
          tester.view.reset();
        });
        try {
          expect(tester.takeException(), isNull);
          expect(
            find.byKey(const ValueKey('music-manager-stored')),
            findsOneWidget,
          );
          expect(
            find.byKey(const ValueKey('music-manager-reachable')),
            findsOneWidget,
          );
          expect(
            find.byKey(const ValueKey('music-manager-verified')),
            findsOneWidget,
          );
          final verify = find.byKey(const ValueKey('music-manager-verify'));
          await tester.scrollUntilVisible(
            verify,
            300,
            scrollable: find.byType(Scrollable).first,
          );
          await tester.pumpAndSettle();
          expect(tester.getRect(verify).height, greaterThanOrEqualTo(48));
          expect(tester.getSemantics(verify).flagsCollection.isButton, true);
          await tester.tap(verify);
          await tester.pumpAndSettle();

          expect(find.text('Living room HomePod'), findsWidgets);
          expect(find.text('Kitchen Cast'), findsOneWidget);
          expect(find.text('Office AirPlay'), findsOneWidget);
          final receiver = find.byKey(
            const ValueKey('music-manager-receiver-homepod-living'),
          );
          final kitchen = find.byKey(
            const ValueKey('music-manager-receiver-cast-kitchen'),
          );
          await tester.scrollUntilVisible(
            kitchen,
            300,
            scrollable: find.byType(Scrollable).first,
          );
          await tester.tap(kitchen);
          await tester.pump();
          await tester.scrollUntilVisible(
            receiver,
            300,
            scrollable: find.byType(Scrollable).first,
          );
          await tester.pumpAndSettle();
          expect(tester.getRect(receiver).height, greaterThanOrEqualTo(48));
          expect(tester.getSemantics(receiver).flagsCollection.isButton, true);
          await tester.tap(receiver);
          await tester.pumpAndSettle();
          expect(
            tester.getSemantics(receiver).flagsCollection.isSelected,
            Tristate.isTrue,
          );
          final migration = find.byKey(
            const ValueKey('music-manager-migrate-legacy'),
          );
          await tester.scrollUntilVisible(
            migration,
            300,
            scrollable: find.byType(Scrollable).first,
          );
          await tester.pumpAndSettle();
          expect(tester.getRect(migration).height, greaterThanOrEqualTo(48));
          expect(tester.getSemantics(migration).flagsCollection.isButton, true);
          final heading = find.byKey(
            const ValueKey('music-manager-playback-heading'),
          );
          await tester.scrollUntilVisible(
            heading,
            300,
            scrollable: find.byType(Scrollable).first,
          );
          await tester.pumpAndSettle();
          expect(tester.getSemantics(heading).flagsCollection.isHeader, true);
          expect(tester.takeException(), isNull);
        } finally {
          semantics.dispose();
        }
      });
    }
  }

  testWidgets('search Enter and queue actions use verified Core state', (
    tester,
  ) async {
    final fixture = await mount(tester, locale: 'en', width: 1200);
    addTearDown(() {
      fixture.account.dispose();
      tester.view.reset();
    });
    final verify = find.byKey(const ValueKey('music-manager-verify'));
    await tester.scrollUntilVisible(
      verify,
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(verify);
    await tester.pumpAndSettle();
    final field = find.byKey(const ValueKey('music-manager-search-field'));
    await tester.scrollUntilVisible(
      field,
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.ensureVisible(field);
    await tester.pumpAndSettle();
    expect(find.byType(CupertinoTextField), findsOneWidget);
    await tester.tap(field);
    await tester.enterText(field, 'Result');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();

    expect(find.text('Result track'), findsOneWidget);
    final l = AppLocalizations.of(tester.element(field));
    expect(find.text(l.musicRadio), findsOneWidget);
    final item = find.byKey(
      const ValueKey('music-manager-item-spotify://track/result'),
    );
    await tester.scrollUntilVisible(
      item,
      300,
      scrollable: find.byType(Scrollable).first,
    );
    Focus.of(tester.element(find.text('Result track'))).requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    final add = find.byKey(const ValueKey('music-manager-queue-add'));
    await tester.scrollUntilVisible(
      add,
      300,
      scrollable: find.byType(Scrollable).first,
    );
    expect(tester.getRect(add).height, greaterThanOrEqualTo(48));
    await tester.tap(add);
    await tester.pumpAndSettle();

    expect(fixture.itemCount, 2);
    expect(
      fixture.calls.where(
        (request) => request.url.path.endsWith('/manager/commands'),
      ),
      hasLength(1),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('backgrounding expires a pending command without replay', (
    tester,
  ) async {
    final fixture = await mount(tester, locale: 'en', width: 1200);
    addTearDown(() {
      fixture.account.dispose();
      tester.view.reset();
    });
    final verify = find.byKey(const ValueKey('music-manager-verify'));
    await tester.scrollUntilVisible(
      verify,
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(verify);
    await tester.pumpAndSettle();
    final pause = find.byKey(const ValueKey('music-manager-pause'));
    await tester.scrollUntilVisible(
      pause,
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    final original = fixture.respond!;
    fixture.respond = (request) async {
      if (request.url.path.endsWith('/manager/commands')) {
        return fixture.json({
          'receipt': {
            'requestId': (jsonDecode(request.body) as Map)['requestId'],
            'targetId': 'homepod-living',
            'operation': 'pause',
            'state': 'succeeded',
            'playerRevision': 7,
            'code': 'authenticated_readback',
            'installAvailable': false,
          },
        }, 201);
      }
      return original(request);
    };
    await tester.tap(pause);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pumpAndSettle();

    expect(
      fixture.calls.where(
        (request) => request.url.path.endsWith('/manager/commands'),
      ),
      hasLength(1),
    );
    expect(find.byKey(const ValueKey('music-manager-verified')), findsNothing);
    expect(find.byType(CupertinoButton), findsNothing);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  });

  testWidgets('legacy player migration requires an explicit central choice', (
    tester,
  ) async {
    final generation = Object();
    final discovery = MusicDiscovery(
      accountGeneration: generation,
      readAt: DateTime.now().toUtc(),
      entries: const [
        MusicAssistantEntry(
          id: 'legacy-entry',
          title: 'Legacy server',
          state: 'loaded',
          disabled: false,
        ),
      ],
      queueTargets: const [
        MusicQueueTarget(
          entityId: 'media_player.legacy_living_room',
          configEntryId: 'legacy-entry',
          name: 'Legacy living room',
          registryId: 'legacy-registry',
          deviceId: 'legacy-device',
          available: true,
          enabled: true,
        ),
      ],
    );
    final fixture = MusicManagerFixture();
    await fixture.account.initialize();
    addTearDown(() {
      fixture.account.dispose();
      tester.view.reset();
    });
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1200, 1000);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          serverAccountControllerProvider.overrideWithValue(fixture.account),
        ],
        child: CupertinoApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: ServerMusicManagerScreen(
            legacyDiscovery: () async => discovery,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final verify = find.byKey(const ValueKey('music-manager-verify'));
    await tester.scrollUntilVisible(
      verify,
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(verify);
    await tester.pumpAndSettle();
    final migration = find.byKey(
      const ValueKey('music-manager-migrate-legacy'),
    );
    await tester.scrollUntilVisible(
      migration,
      300,
      scrollable: find.byType(Scrollable).first,
    );
    expect(tester.widget<CupertinoButton>(migration).onPressed, isNotNull);
    await tester.tap(migration);
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('music-manager-migrate-failure')),
      findsNothing,
    );
    expect(find.textContaining('Legacy living room'), findsOneWidget);
    expect(find.textContaining('Spotify'), findsWidgets);
    expect(find.textContaining('Living room HomePod'), findsWidgets);
    expect(find.textContaining('media_player.legacy'), findsNothing);
    expect(find.textContaining('legacy-entry'), findsNothing);

    await tester.tap(
      find.byKey(const ValueKey('music-manager-migrate-confirm')),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('music-manager-migrate-success')),
      findsOneWidget,
    );
    expect(
      fixture.calls.where(
        (request) => request.url.path.endsWith('/manager/refresh'),
      ),
      hasLength(2),
    );
  });

  testWidgets('retired migration discovery cannot open confirmation', (
    tester,
  ) async {
    final pending = Completer<MusicDiscovery>();
    final fixture = await mount(tester, locale: 'en', width: 1200);
    addTearDown(() {
      fixture.account.dispose();
      tester.view.reset();
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          serverAccountControllerProvider.overrideWithValue(fixture.account),
        ],
        child: CupertinoApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: ServerMusicManagerScreen(legacyDiscovery: () => pending.future),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final verify = find.byKey(const ValueKey('music-manager-verify'));
    await tester.scrollUntilVisible(
      verify,
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(verify);
    await tester.pumpAndSettle();
    final migration = find.byKey(
      const ValueKey('music-manager-migrate-legacy'),
    );
    await tester.scrollUntilVisible(
      migration,
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(migration);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    pending.complete(
      MusicDiscovery(accountGeneration: Object(), readAt: DateTime.now()),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('music-manager-migrate-confirm')),
      findsNothing,
    );
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  });

  testWidgets('legacy chooser never renders an unsafe unbounded label', (
    tester,
  ) async {
    final generation = Object();
    final discovery = MusicDiscovery(
      accountGeneration: generation,
      readAt: DateTime.now().toUtc(),
      entries: const [
        MusicAssistantEntry(
          id: 'legacy-entry',
          title: 'Legacy server',
          state: 'loaded',
          disabled: false,
        ),
      ],
      queueTargets: const [
        MusicQueueTarget(
          entityId: 'media_player.unsafe',
          configEntryId: 'legacy-entry',
          name: '\u202ehttps://token.example',
          registryId: 'legacy-registry-unsafe',
          deviceId: 'legacy-device-unsafe',
          available: true,
          enabled: true,
        ),
        MusicQueueTarget(
          entityId: 'media_player.safe',
          configEntryId: 'legacy-entry',
          name: 'Safe living room',
          registryId: 'legacy-registry-safe',
          deviceId: 'legacy-device-safe',
          available: true,
          enabled: true,
        ),
      ],
    );
    final fixture = MusicManagerFixture();
    await fixture.account.initialize();
    addTearDown(() {
      fixture.account.dispose();
      tester.view.reset();
    });
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1200, 1000);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          serverAccountControllerProvider.overrideWithValue(fixture.account),
        ],
        child: CupertinoApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: ServerMusicManagerScreen(
            legacyDiscovery: () async => discovery,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final verify = find.byKey(const ValueKey('music-manager-verify'));
    await tester.scrollUntilVisible(
      verify,
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(verify);
    await tester.pumpAndSettle();
    final migration = find.byKey(
      const ValueKey('music-manager-migrate-legacy'),
    );
    await tester.scrollUntilVisible(
      migration,
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(migration);
    await tester.pumpAndSettle();

    expect(find.textContaining('token.example'), findsNothing);
    expect(
      find.byKey(const ValueKey('music-manager-migrate-failure')),
      findsNothing,
    );
    expect(find.textContaining('Safe living room'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('music-manager-migrate-confirm')),
      findsOneWidget,
    );
  });
}
