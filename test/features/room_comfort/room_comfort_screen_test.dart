import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/room_comfort/data/room_comfort_controller.dart';
import 'package:larenor/features/room_comfort/domain/room_comfort_models.dart';
import 'package:larenor/features/room_comfort/presentation/room_comfort_screen.dart';

RoomComfortPlan _plan() => RoomComfortPlan(
  coreId: 'a' * 32,
  homeId: 'b' * 32,
  planId: 'c' * 32,
  policyId: 'd' * 32,
  homeRevision: 2,
  policyRevision: 3,
  accountRevision: 4,
  sessionFamilyId: 'e' * 32,
  generatedAt: DateTime.utc(2026, 9, 21),
  rooms: [
    RoomComfortPlanItem(
      roomId: 'f' * 32,
      roomRevision: 5,
      areaId: '1' * 32,
      areaRevision: 6,
      status: ComfortPlanStatus.planned,
      reason: ComfortReason.temperatureLow,
      hvacMode: ComfortHvacMode.heat,
      windowState: ComfortWindowState.closed,
      occupancy: ComfortOccupancy.occupied,
    ),
    RoomComfortPlanItem(
      roomId: '9' * 32,
      roomRevision: 7,
      areaId: '2' * 32,
      areaRevision: 8,
      status: ComfortPlanStatus.blocked,
      reason: ComfortReason.sensorStale,
      hvacMode: ComfortHvacMode.off,
      windowState: ComfortWindowState.closed,
      occupancy: ComfortOccupancy.stale,
    ),
  ],
);

final class _Gateway implements RoomComfortGateway {
  int loads = 0;
  @override
  Future<RoomComfortPlan> loadPlan() async {
    loads++;
    return _plan();
  }

  @override
  void retire() {}
}

Future<_Gateway> _pump(
  WidgetTester tester, {
  required double width,
  required RoomComfortStrings strings,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(width, 1100);
  tester.platformDispatcher.textScaleFactorTestValue = 2;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  final gateway = _Gateway();
  await tester.pumpWidget(
    CupertinoApp(
      home: RoomComfortScreen(
        strings: strings,
        controller: RoomComfortController(
          gateway: gateway,
          isCurrent: () => true,
          coreId: 'a' * 32,
          homeId: 'b' * 32,
          sessionFamilyId: 'e' * 32,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return gateway;
}

void main() {
  for (final language in [
    (RoomComfortStrings.en, 'en'),
    (RoomComfortStrings.tr, 'tr'),
  ]) {
    for (final width in [600.0, 1280.0]) {
      testWidgets('${language.$2} $width at 2x stays readable and adaptive', (
        tester,
      ) async {
        await _pump(tester, width: width, strings: language.$1);
        expect(find.text(language.$1.title), findsOneWidget);
        expect(
          find.text(language.$1.reasons[ComfortReason.sensorStale]!),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
        final first = tester.getTopLeft(
          find.byKey(const ValueKey('comfort-room-f')),
        );
        final second = tester.getTopLeft(
          find.byKey(const ValueKey('comfort-room-9')),
        );
        if (width >= 1000) {
          expect(second.dx, greaterThan(first.dx));
          expect(second.dy, first.dy);
        } else {
          expect(second.dx, first.dx);
          expect(second.dy, greaterThan(first.dy));
        }
        expect(
          tester.getSize(find.byKey(const ValueKey('comfort-refresh'))).height,
          greaterThanOrEqualTo(48),
        );
      });
    }
  }

  testWidgets('TalkBack exposes safety status and refresh action', (
    tester,
  ) async {
    final gateway = await _pump(
      tester,
      width: 1280,
      strings: RoomComfortStrings.en,
    );
    final semantics = tester.ensureSemantics();
    expect(
      tester.getSemantics(find.byKey(const ValueKey('comfort-refresh'))).label,
      RoomComfortStrings.en.refresh,
    );
    expect(
      tester.getSemantics(find.byKey(const ValueKey('comfort-room-9'))).label,
      contains(RoomComfortStrings.en.blocked),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(gateway.loads, 2);
    semantics.dispose();
  });
}
