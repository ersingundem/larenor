import 'dart:convert' show jsonDecode;

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/server/music_manager/presentation/server_music_manager_screen.dart';
import 'package:larenor/features/server/providers/server_providers.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';

import 'server_music_manager_test_support.dart';

void main() {
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
          await tester.scrollUntilVisible(
            receiver,
            300,
            scrollable: find.byType(Scrollable).first,
          );
          await tester.pumpAndSettle();
          expect(tester.getRect(receiver).height, greaterThanOrEqualTo(48));
          expect(tester.getSemantics(receiver).flagsCollection.isButton, true);
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
    expect(find.byType(CupertinoTextField), findsOneWidget);
    await tester.tap(field);
    await tester.enterText(field, 'Result');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();

    expect(find.text('Result track'), findsOneWidget);
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
}
