import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/power_budget/data/power_budget_api.dart';
import 'package:larenor/features/power_budget/data/power_budget_controller.dart';
import 'package:larenor/features/power_budget/domain/power_budget_models.dart';
import 'package:larenor/features/power_budget/presentation/power_budget_screen.dart';
import 'package:larenor/l10n/generated/app_localizations.dart';

const sample = PowerBudgetSnapshot(
  authority: PowerBudgetAuthority(
    coreId: 'core',
    homeId: 'home',
    accountId: 'account',
    sessionId: 'session',
    meterId: 'meter',
    routeId: 'route',
    coreRevision: 1,
    homeRevision: 2,
    accountRevision: 3,
    meterRevision: 4,
    tariffRevision: 5,
    loadRegistryRevision: 6,
    gridLimitRevision: 7,
    overrideRevision: 8,
    planRevision: 9,
    clientSessionRevision: 10,
    routeRevision: 11,
    canControl: true,
  ),
  gridImportW: 11500,
  gridLimitW: 8000,
  tariffMicrosPerKwh: 1250000,
  meterStatus: 'verified',
  tariffStatus: 'verified',
  planId: 'plan',
  planHash: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  planStatus: 'ready',
  requiredReductionW: 3500,
  overrideExpiresAtMs: null,
  controlCapability: 'manual_required',
  commandEndpointAvailable: false,
  actions: [
    PowerBudgetAction(
      loadId: 'charger',
      label: 'EV charger',
      loadRevision: 1,
      reductionW: 3000,
      targetW: 0,
      priority: 10,
    ),
  ],
);

final class _Api implements PowerBudgetApi {
  Completer<PowerBudgetSnapshot>? gate;
  var retired = false;
  @override
  Future<PowerBudgetSnapshot> load() => gate?.future ?? Future.value(sample);
  @override
  void retire() => retired = true;
}

void main() {
  test('late provider result is discarded after route retirement', () async {
    var current = true;
    final api = _Api();
    final controller = PowerBudgetController(api: api, isCurrent: () => current);
    addTearDown(controller.dispose);
    final gate = Completer<PowerBudgetSnapshot>();
    api.gate = gate;
    final pending = controller.load();
    current = false;
    controller.setInteractive(false);
    gate.complete(sample);
    await pending;
    expect(controller.state, PowerBudgetViewState.stale);
    expect(controller.snapshot, isNull);
    expect(api.retired, isTrue);
  });

  for (final locale in const [Locale('en'), Locale('tr')]) {
    for (final width in const [600.0, 1280.0]) {
      testWidgets('power recommendations $width ${locale.languageCode} 2x', (
        tester,
      ) async {
        tester.view.physicalSize = Size(width, 1000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final controller = PowerBudgetController(
          api: _Api(),
          isCurrent: () => true,
        );
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
            home: PowerBudgetScreen(controller: controller),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('EV charger'), findsOneWidget);
        expect(find.byKey(const ValueKey('power-budget-refresh')), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }
  }
}
