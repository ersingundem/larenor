import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/auth/data/ha_discovery.dart';
import 'package:larenor/features/auth/presentation/connect_screen.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _NoDiscovery extends HaDiscoveryService {
  @override
  Future<void> start() async {}
}

class _LateDiscovery extends HaDiscoveryService {
  final _servers = StreamController<List<DiscoveredHaServer>>.broadcast();

  @override
  Stream<List<DiscoveredHaServer>> get servers => _servers.stream;

  @override
  Future<void> start() async {}

  @override
  Future<void> stop() async {}

  void emit() => _servers.add(const []);

  Future<void> close() => _servers.close();
}

void main() {
  testWidgets('disposed discovery and timeout callbacks are retired', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    final discovery = _LateDiscovery();
    addTearDown(discovery.close);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          haDiscoveryFactoryProvider.overrideWithValue(() => discovery),
        ],
        child: const CupertinoApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: ConnectScreen(),
        ),
      ),
    );

    await tester.pumpWidget(const SizedBox());
    discovery.emit();
    await tester.pump(const Duration(seconds: 7));

    expect(tester.takeException(), isNull);
  });

  for (final lang in ['en', 'tr']) {
    testWidgets('malformed URL recovers the connect form in $lang', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      FlutterSecureStorage.setMockInitialValues({});
      tester.view.physicalSize = const Size(700, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            haDiscoveryFactoryProvider.overrideWithValue(_NoDiscovery.new),
          ],
          child: CupertinoApp(
            locale: Locale(lang),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: const ConnectScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final inputs = find.byType(CupertinoTextField);
      await tester.enterText(inputs.at(0), 'https://bad host/');
      await tester.enterText(inputs.at(1), 'synthetic-input');
      final l10n = AppLocalizations.of(
        tester.element(find.byType(ConnectScreen)),
      );
      final connect = find.widgetWithText(CupertinoButton, l10n.commonConnect);
      await tester.ensureVisible(connect);
      await tester.tap(connect);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byType(CupertinoActivityIndicator), findsNothing);
      expect(tester.widget<CupertinoButton>(connect).onPressed, isNotNull);
      expect(find.text(l10n.connectErrorUrl), findsOneWidget);
      await tester.pump(const Duration(seconds: 7));
      await tester.pumpWidget(const SizedBox());
    });
  }
}
