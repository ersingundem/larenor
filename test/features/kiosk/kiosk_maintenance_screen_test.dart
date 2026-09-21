import 'package:flutter/cupertino.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/kiosk/data/kiosk_usage_repository.dart';
import 'package:larenor/features/kiosk/presentation/kiosk_maintenance_screen.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';

final class _Store implements KioskUsageStore {
  String? value;
  @override
  Future<String?> read() async => value;
  @override
  Future<void> write(String value) async => this.value = value;
}

Future<void> _mount(
  WidgetTester tester, {
  required Locale locale,
  required double width,
  required KioskUsageRepository repository,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(width, 1000);
  addTearDown(tester.view.reset);
  await tester.pumpWidget(CupertinoApp(
    locale: locale,
    supportedLocales: AppLocalizations.supportedLocales,
    localizationsDelegates: const [
      AppLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
    ],
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(textScaler: const TextScaler.linear(2)),
      child: child!,
    ),
    home: KioskMaintenanceScreen(repository: repository),
  ));
  await tester.pumpAndSettle();
}

void main() {
  for (final locale in const [Locale('en'), Locale('tr')]) {
    for (final width in const [600.0, 1280.0]) {
      testWidgets('${locale.languageCode} $width 2x exposes safe maintenance and CSV preview', (tester) async {
        final repository = KioskUsageRepository(
          store: _Store(),
          now: () => DateTime.utc(2026, 9, 21),
        );
        await repository.record(KioskUsageEvent.rendererFailure);
        await repository.record(KioskUsageEvent.recoveryAttempt);
        await _mount(tester, locale: locale, width: width, repository: repository);

        expect(find.byKey(const ValueKey('kiosk-maintenance-csv')), findsOneWidget);
        expect(find.textContaining('2026-09-21,1,0,1,0,0'), findsOneWidget);
        final refresh = find.byKey(const ValueKey('kiosk-maintenance-refresh'));
        expect(tester.getSize(refresh).height, greaterThanOrEqualTo(48));
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('corrupt local journal shows error without stale counts', (tester) async {
    final store = _Store()..value = '{bad';
    await _mount(
      tester,
      locale: const Locale('en'),
      width: 600,
      repository: KioskUsageRepository(store: store),
    );
    expect(find.textContaining('could not be verified'), findsOneWidget);
    expect(find.byKey(const ValueKey('kiosk-maintenance-csv')), findsNothing);
  });
}
