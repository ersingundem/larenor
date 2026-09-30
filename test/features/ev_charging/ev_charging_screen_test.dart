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
  Gateway({this.loseAck = false});
  final bool loseAck;
  int loads = 0, previews = 0, confirms = 0, results = 0;
  String? submittedCommandId;
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
    submittedCommandId = commandId;
    if (loseAck) throw StateError('lost_ack');
    return EvChargeReceipt(
      commandId: commandId,
      previewId: plan.previewId,
      planHash: plan.planHash,
      status: 'awaiting_readback',
    );
  }

  @override
  Future<EvChargeReceipt> result(EvChargePlan plan, String commandId) async {
    results++;
    if (commandId != submittedCommandId) throw StateError('wrong_command');
    return EvChargeReceipt(
      commandId: commandId,
      previewId: plan.previewId,
      planHash: plan.planHash,
      status: 'verified',
      targetCurrentAmp: 16,
      observedCurrentAmp: 16,
      observedAt: DateTime.utc(2026, 9, 21, 0, 1),
    );
  }

  @override
  void retire() {}
}

Future<Gateway> mount(
  WidgetTester tester,
  EvChargingStrings strings,
  double width, {
  bool loseAck = false,
  Iterable<String>? ids,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(width, 1200);
  tester.platformDispatcher.textScaleFactorTestValue = 2;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  final gateway = Gateway(loseAck: loseAck);
  final values = ids?.iterator;
  await tester.pumpWidget(
    CupertinoApp(
      home: EvChargingScreen(
        strings: strings,
        controller: EvChargingController(
          gateway: gateway,
          isCurrent: () => true,
          id: () {
            if (values == null) return '6' * 32;
            if (!values.moveNext()) throw StateError('no_id');
            return values.current;
          },
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
    final dialogFocus = find.byKey(
      const ValueKey('ev-charge-confirm-dialog-focus'),
    );
    expect(dialogFocus, findsOneWidget);
    final dynamic dialogFocusState = tester.state(dialogFocus);
    expect(dialogFocusState.focusNode.hasFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(gateway.confirms, 1);
    expect(find.text(EvChargingStrings.en.uncertain), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('ev-charge-refresh')));
    await tester.pumpAndSettle();
    expect(gateway.results, 1);
    expect(find.text(EvChargingStrings.en.ready), findsWidgets);
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

  testWidgets(
    'lost ACK keeps the submitted command id for GET reconciliation',
    (tester) async {
      final gateway = await mount(
        tester,
        EvChargingStrings.en,
        1280,
        loseAck: true,
        ids: ['1' * 32, '2' * 32, '3' * 32],
      );
      await tester.tap(find.byKey(const ValueKey('ev-charge-preview')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('ev-charge-confirm')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.byType(CupertinoAlertDialog),
          matching: find.text(EvChargingStrings.en.confirm),
        ),
      );
      await tester.pumpAndSettle();
      expect(gateway.submittedCommandId, '2' * 32);
      expect(find.text(EvChargingStrings.en.uncertain), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('ev-charge-refresh')));
      await tester.pumpAndSettle();
      expect(gateway.results, 1);
      expect(
        find.textContaining(EvChargingStrings.en.chargerLimit),
        findsOneWidget,
      );
    },
  );
}
