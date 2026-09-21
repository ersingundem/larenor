import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/workshop/data/workshop_controller.dart';
import 'package:larenor/features/workshop/domain/workshop_models.dart';
import 'package:larenor/features/workshop/presentation/workshop_screen.dart';

WorkshopPrinter printer({required String id, required bool safe}) =>
    WorkshopPrinter(
      coreId: 'a' * 32,
      homeId: 'b' * 32,
      id: id * 32,
      revision: 4,
      name: safe ? 'Workshop One' : 'Workshop Two',
      service: WorkshopServiceRef(id: 'e' * 32, revision: 3),
      job: WorkshopJob(
        revision: 7,
        id: 'f' * 32,
        state: WorkshopJobState.printing,
        progressPermille: 420,
        remainingSeconds: 900,
      ),
      material: const WorkshopMaterial(
        revision: 5,
        kind: WorkshopMaterialKind.pla,
        remainingGrams: 280,
      ),
      safety: WorkshopSafety(
        revision: 9,
        connectivity: WorkshopConnectivity.online,
        thermal: safe ? WorkshopThermal.normal : WorkshopThermal.runaway,
        filament: WorkshopFilament.available,
        door: WorkshopDoor.closed,
        emergency: WorkshopEmergency.clear,
        observedAt: DateTime.utc(2026, 9, 21),
        freshness: WorkshopFreshness.current,
      ),
      availableActions: safe
          ? const [WorkshopAction.pause, WorkshopAction.cancel]
          : const [],
    );

WorkshopPrinter safePrinter() => printer(id: 'a', safe: true);
WorkshopPrinter hazardPrinter() => printer(id: 'b', safe: false);

WorkshopPreview previewFor(WorkshopPrinter printer, WorkshopAction action) =>
    WorkshopPreview(
      coreId: printer.coreId,
      homeId: printer.homeId,
      id: '1' * 32,
      printerId: printer.id,
      action: action,
      confirmationToken: 't' * 43,
      expiresAt: DateTime.now().toUtc().add(const Duration(minutes: 1)),
    );

WorkshopIntentReceipt receiptFor(WorkshopPreview preview) =>
    WorkshopIntentReceipt(
      id: '2' * 32,
      sequence: 1,
      printerId: preview.printerId,
      action: preview.action,
      effect: WorkshopIntentEffect.notDispatched,
      authority: const WorkshopIntentAuthority(
        printerRevision: 4,
        serviceRevision: 3,
        jobRevision: 7,
        materialRevision: 5,
        safetyRevision: 9,
      ),
      createdAt: DateTime.now().toUtc(),
    );

final class _Gateway implements WorkshopGateway {
  int confirmations = 0;
  @override
  Future<List<WorkshopPrinter>> load() async => [
    safePrinter(),
    hazardPrinter(),
  ];
  @override
  Future<WorkshopPreview> preview({
    required WorkshopPrinter printer,
    required WorkshopAction action,
    required String requestKey,
  }) async => previewFor(printer, action);
  @override
  Future<WorkshopIntentReceipt> confirm(WorkshopPreview preview) async {
    confirmations++;
    return receiptFor(preview);
  }

  @override
  void retire() {}
}

Future<_Gateway> pump(
  WidgetTester tester, {
  required double width,
  required WorkshopStrings strings,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(width, 900);
  tester.platformDispatcher.textScaleFactorTestValue = 2;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  final gateway = _Gateway();
  await tester.pumpWidget(
    CupertinoApp(
      home: WorkshopScreen(
        controller: WorkshopController(
          gateway: gateway,
          isCurrent: () => true,
          requestKey: () => 'pause-request-key-0001',
        ),
        strings: strings,
      ),
    ),
  );
  await tester.pumpAndSettle();
  return gateway;
}

void main() {
  for (final entry in [
    (WorkshopStrings.en, 'en'),
    (WorkshopStrings.tr, 'tr'),
  ]) {
    for (final width in const [600.0, 1280.0]) {
      testWidgets('${entry.$2} $width at 2x is readable and adaptive', (
        tester,
      ) async {
        await pump(tester, width: width, strings: entry.$1);
        expect(find.text(entry.$1.title), findsOneWidget);
        expect(find.text(entry.$1.thermalRunaway), findsOneWidget);
        expect(tester.takeException(), isNull);
        final first = tester.getTopLeft(
          find.byKey(const ValueKey('workshop-a')),
        );
        final second = tester.getTopLeft(
          find.byKey(const ValueKey('workshop-b')),
        );
        if (width >= 1000) {
          expect(second.dx, greaterThan(first.dx));
          expect(second.dy, first.dy);
        } else {
          expect(second.dx, first.dx);
          expect(second.dy, greaterThan(first.dy));
        }
        for (final key in ['workshop-pause-a', 'workshop-cancel-a']) {
          expect(
            tester.getSize(find.byKey(ValueKey(key))).height,
            greaterThanOrEqualTo(48),
          );
        }
      });
    }
  }

  testWidgets('keyboard and TalkBack keep confirmation explicit', (
    tester,
  ) async {
    final gateway = await pump(
      tester,
      width: 1280,
      strings: WorkshopStrings.en,
    );
    final semantics = tester.ensureSemantics();
    final pause = find.byKey(const ValueKey('workshop-pause-a'));
    expect(tester.getSemantics(pause).label, WorkshopStrings.en.previewPause);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.text(WorkshopStrings.en.confirmTitle), findsOneWidget);
    expect(gateway.confirmations, 0);
    final confirm = find.byKey(const ValueKey('workshop-confirm'));
    expect(tester.getSize(confirm).height, greaterThanOrEqualTo(48));
    await tester.tap(confirm);
    await tester.pumpAndSettle();
    expect(gateway.confirmations, 1);
    expect(find.text(WorkshopStrings.en.intentRecorded), findsOneWidget);
    semantics.dispose();
  });
}
