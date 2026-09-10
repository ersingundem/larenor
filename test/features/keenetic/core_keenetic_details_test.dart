import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/keenetic/core/domain/core_keenetic_models.dart';
import 'package:larenor/features/keenetic/core/presentation/core_keenetic_screen.dart';
import 'package:larenor/features/server/domain/server_models.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';

Map<String, dynamic> pageJson() => {
  'snapshot': 'a' * 64,
  'nextAfter': 'b' * 64,
  'entries': [
    {
      'kind': 'interface',
      'id': 'ISP',
      'name': 'Internet',
      'interfaceKind': 'wan',
      'online': true,
      'address': '198.51.100.2',
      'rxBytes': 1000,
      'txBytes': 500,
      'guest': null,
      'ssid': null,
      'band': null,
      'channel': null,
      'signalDbm': null,
    },
    {
      'kind': 'interface',
      'id': 'guest0',
      'name': 'Guest Wi-Fi',
      'interfaceKind': 'wifi',
      'online': true,
      'address': null,
      'rxBytes': 800,
      'txBytes': 300,
      'guest': true,
      'ssid': 'Larenor Guest',
      'band': '5',
      'channel': 44,
      'signalDbm': -61,
    },
    {
      'kind': 'client',
      'id': 'client-1',
      'name': 'Salon Tablet',
      'ipAddress': '192.168.1.20',
      'macHash': '0123456789abcdef',
      'interfaceId': 'guest0',
      'online': true,
      'registered': true,
      'internetAccess': 'allowed',
      'band': '5',
      'signalDbm': -58,
    },
  ],
};

void main() {
  test('detail page parser rejects schema drift and unsafe identifiers', () {
    final page = CoreKeeneticDetailsPage.fromJson(pageJson());
    expect(page.entries, hasLength(3));
    expect(page.interfaces, hasLength(2));
    expect(page.clients.single.macHash, '0123456789abcdef');
    for (final invalid in [
      {...pageJson(), 'secret': 'router-password'},
      {...pageJson(), 'nextAfter': '../escape'},
      {
        ...pageJson(),
        'entries': [
          {
            ...(pageJson()['entries'] as List).last as Map,
            'macAddress': 'AA:BB:CC:DD:EE:FF',
          },
        ],
      },
    ]) {
      expect(
        () => CoreKeeneticDetailsPage.fromJson(invalid),
        throwsA(isA<LarenorServerException>()),
      );
    }
  });

  for (final width in [600.0, 1280.0]) {
    testWidgets('$width master-detail supports search, keyboard and 2x text', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = Size(width, 900);
      addTearDown(tester.view.reset);
      var refreshed = 0, loaded = 0;
      final semantics = tester.ensureSemantics();
      await tester.pumpWidget(
        CupertinoApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
          home: CupertinoPageScaffold(
            child: SafeArea(
              child: CoreKeeneticDetailsPanel(
                page: CoreKeeneticDetailsPage.fromJson(pageJson()),
                enabled: true,
                isCurrent: () => true,
                onRefresh: () => refreshed++,
                onLoadMore: () => loaded++,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Internet'), findsWidgets);
      expect(find.text('Salon Tablet'), findsOneWidget);
      await tester.enterText(find.byType(CupertinoSearchTextField), 'tablet');
      await tester.pump();
      expect(find.text('Salon Tablet'), findsOneWidget);
      expect(find.text('Guest Wi-Fi'), findsNothing);
      await tester.enterText(find.byType(CupertinoSearchTextField), '');
      await tester.pump();
      await tester.tap(find.text('Guest Wi-Fi').first);
      await tester.pump();
      expect(find.text('Larenor Guest'), findsOneWidget);
      expect(find.textContaining('44'), findsOneWidget);
      expect(find.textContaining('-61'), findsOneWidget);
      expect(find.textContaining('AA:BB'), findsNothing);
      expect(
        find.bySemanticsLabel(RegExp('Guest Wi-Fi.*Larenor Guest')),
        findsWidgets,
      );
      final buttons = tester.widgetList<CupertinoButton>(
        find.byType(CupertinoButton),
      );
      expect(buttons, isNotEmpty);
      expect(
        buttons.every((button) => (button.minimumSize?.height ?? 0) >= 48),
        isTrue,
      );
      await tester.tap(
        find.byKey(const ValueKey('core-keenetic-details-refresh')),
      );
      await tester.pump();
      expect(refreshed, 1);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(loaded, lessThanOrEqualTo(1));
      semantics.dispose();
    });
  }

  testWidgets('stale panel clears detail actions and reports status', (
    tester,
  ) async {
    await tester.pumpWidget(
      CupertinoApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: CoreKeeneticDetailsPanel(
          page: null,
          enabled: false,
          failure: 'keenetic_snapshot_unsupported',
          stale: true,
          isCurrent: () => false,
          onRefresh: null,
          onLoadMore: null,
        ),
      ),
    );
    expect(find.textContaining('stale'), findsOneWidget);
    expect(find.textContaining('not supported'), findsOneWidget);
  });
}
