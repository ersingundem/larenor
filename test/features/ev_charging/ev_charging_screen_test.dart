import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/ev_charging/data/ev_charging_controller.dart';
import 'package:larenor/features/ev_charging/domain/ev_charging_models.dart';
import 'package:larenor/features/ev_charging/presentation/ev_charging_screen.dart';

final charger = EvChargerCapability(
  id: '3' * 32,
  label: 'Garage charger',
  chargerRevision: 4,
  scheduleRevision: 7,
  tariffRevision: 5,
  powerBudgetRevision: 7,
  currentSoc: 40,
  batteryCapacityWh: 40000,
  maxCurrentAmp: 16,
);

final class Gateway implements EvChargingGateway {
  int loads = 0, previews = 0, confirms = 0;
  @override
  Future<EvChargeCapability> capability() async {
    loads++;
    return EvChargeCapability(
      coreId: '1' * 32,
      homeId: '2' * 32,
      state: EvCapabilityState.ready,
      providerKind: 'ocpp',
      canPlan: true,
      canControl: true,
      reason: 'ready',
      chargers: [charger],
    );
  }

  @override
  Future<EvChargePlan> preview({
    required EvChargerCapability charger,
    required String previewId,
    required DateTime departure,
    required int targetSoc,
  }) async {
    previews++;
    return EvChargePlan(
      coreId: '1' * 32,
      homeId: '2' * 32,
      chargerId: charger.id,
      accountId: '4' * 32,
      sessionFamilyId: '5' * 32,
      previewId: previewId,
      planHash: 'a' * 64,
      chargerRevision: 4,
      scheduleRevision: 7,
      requiredWh: 16000,
      status: 'ready',
      slots: [
        EvChargeSlot(
          start: DateTime.utc(2026, 9, 21),
          end: DateTime.utc(2026, 9, 21, 1),
          currentAmp: 16,
          energyWh: 3680,
          tariffMicrosPerKwh: 100,
        ),
      ],
    );
  }

  @override
  Future<EvChargeReceipt> confirm(EvChargePlan plan, String commandId) async {
    confirms++;
    return EvChargeReceipt(
      commandId: commandId,
      previewId: plan.previewId,
      planHash: plan.planHash,
      status: 'awaiting_readback',
    );
  }

  @override
  void retire() {}
}

Future<Gateway> mount(
  WidgetTester tester,
  EvChargingStrings strings,
  double width,
) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(width, 1200);
  tester.platformDispatcher.textScaleFactorTestValue = 2;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  final gateway = Gateway();
  await tester.pumpWidget(
    CupertinoApp(
      home: EvChargingScreen(
        strings: strings,
        controller: EvChargingController(
          gateway: gateway,
          isCurrent: () => true,
          id: () => '6' * 32,
          now: () => DateTime.utc(2026, 9, 21),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return gateway;
}

void main() {
  for (final value in [
    (EvChargingStrings.en, 'en'),
    (EvChargingStrings.tr, 'tr'),
  ]) {
    for (final width in [600.0, 1280.0]) {
      testWidgets('${value.$2} $width at 2x exposes safe charging plan', (
        tester,
      ) async {
        final gateway = await mount(tester, value.$1, width);
        expect(find.text(value.$1.title), findsOneWidget);
        expect(find.textContaining('40%'), findsOneWidget);
        final preview = find.byKey(const ValueKey('ev-charge-preview'));
        expect(tester.getSize(preview).height, greaterThanOrEqualTo(48));
        await tester.ensureVisible(preview);
        await tester.tap(preview);
        await tester.pumpAndSettle();
        expect(gateway.previews, 1);
        expect(find.byKey(const ValueKey('ev-charge-plan')), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('keyboard confirm preserves uncertain readback language', (
    tester,
  ) async {
    final gateway = await mount(tester, EvChargingStrings.en, 1280);
    await tester.tap(find.byKey(const ValueKey('ev-charge-preview')));
    await tester.pumpAndSettle();
    final confirm = find.byKey(const ValueKey('ev-charge-confirm'));
    final focus = find.descendant(of: confirm, matching: find.byType(Focus));
    final dynamic focusState = tester.state(focus.first);
    focusState.focusNode.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(gateway.confirms, 1);
    expect(find.text(EvChargingStrings.en.uncertain), findsOneWidget);
  });

  testWidgets('changing a goal invalidates its exact preview', (tester) async {
    final gateway = await mount(tester, EvChargingStrings.en, 1280);
    await tester.tap(find.byKey(const ValueKey('ev-charge-preview')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('ev-charge-confirm')), findsOneWidget);
    await tester.tap(find.text('4 hours'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('ev-charge-confirm')), findsNothing);
    expect(gateway.confirms, 0);
  });
}
