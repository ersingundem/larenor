import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/server/music_manager/domain/server_music_manager_models.dart';
import 'package:larenor/features/server/music_manager/presentation/server_music_longform_card.dart';
import 'package:larenor/features/server/music_manager/presentation/server_music_manager_screen.dart';
import 'package:larenor/features/server/providers/server_providers.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'server_music_manager_test_support.dart';

ServerMusicLongformCatalog _catalog() => ServerMusicLongformCatalog.fromJson({
  'requestId': 'f' * 32,
  'managerRevision': 6,
  'items': [
    {
      'uri': 'library://audiobook/private-book',
      'name': 'The Long Book',
      'mediaType': 'audiobook',
      'providerInstanceId': 'library--main',
      'durationSeconds': 3600.0,
      'resumePositionSeconds': 900.0,
      'fullyPlayed': false,
      'chapters': [
        {
          'position': 0,
          'name': 'Opening',
          'startSeconds': 0.0,
          'endSeconds': 1200.0,
        },
      ],
    },
  ],
});

Future<void> _mount(
  WidgetTester tester, {
  required String locale,
  required double width,
  ServerMusicLongformCatalog? catalog,
  String? failure,
  VoidCallback? retry,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(width, 900);
  await tester.pumpWidget(
    CupertinoApp(
      locale: Locale(locale),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: const TextScaler.linear(2)),
        child: child!,
      ),
      home: CupertinoPageScaffold(
        child: SafeArea(
          child: SingleChildScrollView(
            child: ServerMusicLongformCard(
              catalog: catalog,
              failure: failure,
              busy: false,
              onRetry: retry,
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final locale in ['en', 'tr']) {
    for (final width in [600.0, 1280.0]) {
      testWidgets('$locale longform card fits $width at 2x', (tester) async {
        final semantics = tester.ensureSemantics();
        try {
          await _mount(
            tester,
            locale: locale,
            width: width,
            catalog: _catalog(),
          );

          expect(tester.takeException(), isNull);
          expect(find.text('The Long Book'), findsOneWidget);
          expect(find.textContaining('25%'), findsWidgets);
          expect(find.textContaining('Opening'), findsWidgets);
          final item = find.byKey(const ValueKey('music-longform-item-0'));
          expect(
            tester.getSemantics(item).label,
            isNot(contains('private-book')),
          );
        } finally {
          semantics.dispose();
          tester.view.reset();
        }
      });
    }
  }

  testWidgets('empty and error states are explicit and retry is accessible', (
    tester,
  ) async {
    addTearDown(tester.view.reset);
    await _mount(
      tester,
      locale: 'en',
      width: 600,
      catalog: ServerMusicLongformCatalog.fromJson({
        'requestId': 'f' * 32,
        'managerRevision': 6,
        'items': <Object>[],
      }),
    );
    expect(find.byKey(const ValueKey('music-longform-empty')), findsOneWidget);

    var retried = false;
    await _mount(
      tester,
      locale: 'tr',
      width: 600,
      failure: 'connection_failed',
      retry: () => retried = true,
    );
    final retry = find.byKey(const ValueKey('music-longform-retry'));
    expect(retry, findsOneWidget);
    expect(tester.getRect(retry).height, greaterThanOrEqualTo(48));
    await tester.tap(retry);
    expect(retried, true);
    expect(tester.takeException(), isNull);
  });

  testWidgets('verified Media screen loads the authority-bound longform card', (
    tester,
  ) async {
    final fixture = MusicManagerFixture();
    await fixture.account.initialize();
    addTearDown(() {
      fixture.account.dispose();
      tester.view.reset();
    });
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1280, 1000);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          serverAccountControllerProvider.overrideWithValue(fixture.account),
        ],
        child: const CupertinoApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: ServerMusicManagerScreen(),
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
    final card = find.byKey(const ValueKey('music-longform-card'));
    await tester.scrollUntilVisible(
      card,
      300,
      scrollable: find.byType(Scrollable).first,
    );

    expect(find.text('Fixture audiobook'), findsOneWidget);
    expect(
      fixture.calls.where(
        (request) => request.url.path.endsWith('/manager/catalog/in-progress'),
      ),
      hasLength(1),
    );
    expect(tester.takeException(), isNull);
  });
}
