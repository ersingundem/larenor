import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/irrigation_budget/data/irrigation_budget_api.dart';
import 'package:larenor/features/irrigation_budget/data/irrigation_budget_controller.dart';
import 'package:larenor/features/irrigation_budget/domain/irrigation_budget_models.dart';
import 'package:larenor/features/irrigation_budget/presentation/irrigation_budget_screen.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';

const sample = IrrigationBudgetSnapshot(
  authority: IrrigationBudgetAuthority(
    coreId: 'core',
    homeId: 'home',
    accountId: 'account',
    sessionFamilyId: 'family',
    policyId: 'policy',
    routeId: 'route',
    homeRevision: 1,
    accountRevision: 2,
    policyRevision: 3,
    budgetRevision: 4,
    clientSessionRevision: 5,
    routeRevision: 6,
  ),
  planId: 'plan',
  generatedAtMs: 1020000,
  forecastStatus: 'available',
  rainMilliMm: 1250,
  dailyLimitMl: 100000,
  usedMl: 12000,
  plannedMl: 18000,
  estimatedCostMicros: 360000,
  controlCapability: 'manual_required',
  commandEndpointAvailable: false,
  zones: [
    IrrigationZoneBudget(
      zoneId: 'zone',
      zoneRevision: 1,
      areaName: 'Back garden',
      plantName: 'Tomatoes',
      moisturePermille: 300,
      soilReadingRevision: 1,
      status: 'planned',
      reason: 'moisture_deficit',
      durationSeconds: 600,
      estimatedWaterMl: 18000,
    ),
  ],
);

final class _Api implements IrrigationBudgetApi {
  Completer<IrrigationBudgetSnapshot>? gate;
  var retired = false;
  @override
  Future<IrrigationBudgetSnapshot> load() => gate?.future ?? Future.value(sample);
  @override
  void retire() => retired = true;
}

void main() {
  test('late budget result is discarded after route retirement', () async {
    var current = true;
    final api = _Api();
    final controller = IrrigationBudgetController(api: api, isCurrent: () => current);
    addTearDown(controller.dispose);
    final gate = Completer<IrrigationBudgetSnapshot>();
    api.gate = gate;
    final pending = controller.load();
    current = false;
    controller.setInteractive(false);
    gate.complete(sample);
    await pending;
    expect(controller.state, IrrigationBudgetViewState.stale);
    expect(controller.snapshot, isNull);
    expect(api.retired, isTrue);
  });

  for (final locale in const [Locale('en'), Locale('tr')]) {
    for (final width in const [600.0, 1280.0]) {
      testWidgets('irrigation budget $width ${locale.languageCode} 2x', (tester) async {
        tester.view.physicalSize = Size(width, 1200);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final controller = IrrigationBudgetController(api: _Api(), isCurrent: () => true);
        addTearDown(controller.dispose);
        await tester.pumpWidget(
          CupertinoApp(
            locale: locale,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(textScaler: const TextScaler.linear(2)),
              child: child!,
            ),
            home: IrrigationBudgetScreen(controller: controller),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('Back garden'), findsOneWidget);
        expect(find.text('Tomatoes'), findsOneWidget);
        final refresh = find.byKey(const ValueKey('irrigation-budget-refresh'));
        expect(refresh, findsOneWidget);
        expect(tester.getSize(refresh).height, greaterThanOrEqualTo(48));
        expect(find.byKey(const ValueKey('irrigation-valve-command')), findsNothing);
        expect(tester.takeException(), isNull);
      });
    }
  }
}
