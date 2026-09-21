import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/resource_reservations/data/resource_reservation_controller.dart';
import 'package:larenor/features/resource_reservations/presentation/resource_reservation_screen.dart';

import 'resource_reservation_controller_test.dart';

Future<ResourceReservationController> pumpReservationScreen(
  WidgetTester tester, {
  required Size size,
  required ResourceReservationStrings strings,
  required FakeReservationApi api,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final controller = ResourceReservationController(
    api,
    commandIds: () => 'ui-command',
  );
  await tester.pumpWidget(
    MediaQuery(
      data: MediaQueryData(size: size, textScaler: const TextScaler.linear(2)),
      child: CupertinoApp(
        home: ResourceReservationScreen(
          controller: controller,
          authority: reservationAuthorityA,
          strings: strings,
        ),
      ),
    ),
  );
  api.snapshots.single.complete(
    snapshot(reservationAuthorityA, reservations: [reservation()]),
  );
  await tester.pumpAndSettle();
  return controller;
}

void main() {
  testWidgets('EN/TR 600/1200 @2x exposes timezone DST and 48dp actions', (
    tester,
  ) async {
    for (final sample in [
      (const Size(600, 900), ResourceReservationStrings.tr),
      (const Size(1200, 800), ResourceReservationStrings.en),
    ]) {
      final api = FakeReservationApi();
      await pumpReservationScreen(
        tester,
        size: sample.$1,
        strings: sample.$2,
        api: api,
      );
      expect(find.textContaining('Europe/Berlin'), findsWidgets);
      expect(find.text(sample.$2.laterFold), findsWidgets);
      expect(
        tester.getSize(find.byKey(const ValueKey('reservation-create'))).height,
        greaterThanOrEqualTo(48),
      );
      expect(
        tester.getSize(find.byKey(const ValueKey('reservation-export'))).height,
        greaterThanOrEqualTo(48),
      );
      expect(
        tester
            .getSize(
              find.byKey(const ValueKey('reservation-cancel-reservation-1')),
            )
            .height,
        greaterThanOrEqualTo(48),
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    }
  });

  testWidgets(
    'TalkBack labels and keyboard activate bounded read-only export',
    (tester) async {
      final semantics = tester.ensureSemantics();
      final api = FakeReservationApi();
      await pumpReservationScreen(
        tester,
        size: const Size(1200, 800),
        strings: ResourceReservationStrings.en,
        api: api,
      );
      final export = find.byKey(const ValueKey('reservation-export'));
      await tester.ensureVisible(export);
      await tester.pumpAndSettle();
      expect(
        tester.getSemantics(export),
        matchesSemantics(
          label: 'Read reservation export',
          isButton: true,
          hasEnabledState: true,
          isEnabled: true,
          hasTapAction: true,
        ),
      );
      final keyboardTarget = find.descendant(
        of: export,
        matching: find.byType(CupertinoButton),
      );
      Actions.invoke(
        tester.element(keyboardTarget.first),
        const ActivateIntent(),
      );
      await tester.pumpAndSettle();
      expect(api.exportReads, 1);
      expect(api.createCalls, 0);
      semantics.dispose();
    },
  );
}
