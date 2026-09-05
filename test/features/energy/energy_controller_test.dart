import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/energy/data/energy_controller.dart';
import 'package:larenor/features/energy/data/energy_repository.dart';
import 'package:larenor/features/energy/domain/energy_models.dart';

import 'energy_fixture.dart';

EnergyController controllerFor(FakeEnergyApi api) => EnergyController(
  repository: EnergyRepository(api: api, now: () => energyNow),
);

void main() {
  testWidgets(
    'reader is lazy, shared across listeners and stopped on last cancellation',
    (tester) async {
      final api = FakeEnergyApi();
      final controller = controllerFor(api);
      addTearDown(controller.dispose);
      await tester.pump(const Duration(minutes: 10));
      expect(api.calls, isEmpty);
      await controller.refresh();
      expect(api.calls, isEmpty);
      final first = controller.changes.listen((_) {});
      final second = controller.changes.listen((_) {});
      await tester.pump();
      expect(api.calls.where((value) => value == 'config'), hasLength(1));
      expect(controller.state.snapshot?.meters.single.reportedTotal, 3);
      unawaited(first.cancel());
      await tester.pump();
      await tester.pump(const Duration(minutes: 5));
      expect(api.calls.where((value) => value == 'config'), hasLength(2));
      unawaited(second.cancel());
      await tester.pump();
      await tester.pump(const Duration(minutes: 20));
      expect(api.calls.where((value) => value == 'config'), hasLength(2));
    },
  );

  testWidgets(
    'many refreshes coalesce and changed range drops stale work before later reads',
    (tester) async {
      final gate = Completer<void>();
      final api = FakeEnergyApi()..gate = gate;
      final controller = controllerFor(api);
      addTearDown(controller.dispose);
      final seen = <EnergyViewState>[];
      final listener = controller.changes.listen(seen.add);
      await tester.pump();
      for (var i = 0; i < 20; i++) {
        unawaited(controller.refresh());
      }
      controller.setRange(EnergyRange.last7Days);
      expect(api.calls, ['config', 'prefs', 'info']);
      expect(api.maxActive, 3);
      gate.complete();
      await tester.pump();
      expect(api.calls.where((value) => value == 'config'), hasLength(2));
      expect(api.calls.where((value) => value == 'metadata'), hasLength(1));
      expect(controller.state.snapshot?.period?.range, EnergyRange.last7Days);
      expect(
        seen
            .where((state) => state.snapshot != null)
            .map((state) => state.snapshot!.period!.range),
        everyElement(EnergyRange.last7Days),
      );
      unawaited(listener.cancel());
      await tester.pump();
    },
  );

  for (final mode in ['background', 'hidden', 'cancelled', 'disposed']) {
    testWidgets(
      '$mode cancels late work and timer without publishing a stale snapshot',
      (tester) async {
        final gate = Completer<void>();
        final api = FakeEnergyApi()..gate = gate;
        final controller = controllerFor(api);
        addTearDown(controller.dispose);
        final seen = <EnergyViewState>[];
        var listener = controller.changes.listen(seen.add);
        await tester.pump();
        switch (mode) {
          case 'background':
            controller.setForeground(false);
          case 'hidden':
            controller.setVisible(false);
          case 'cancelled':
            unawaited(listener.cancel());
            await tester.pump();
          case 'disposed':
            controller.dispose();
        }
        gate.complete();
        await tester.pump();
        await tester.pump(const Duration(minutes: 20));
        expect(api.calls, ['config', 'prefs', 'info']);
        expect(seen.any((state) => state.snapshot != null), isFalse);
        if (mode != 'disposed') {
          if (mode == 'background') controller.setForeground(true);
          if (mode == 'hidden') controller.setVisible(true);
          if (mode == 'cancelled') {
            listener = controller.changes.listen(seen.add);
          }
          await tester.pump();
          expect(controller.state.snapshot?.meters.single.reportedTotal, 3);
          expect(api.calls.where((value) => value == 'config'), hasLength(2));
        }
        unawaited(listener.cancel());
        await tester.pump();
      },
    );
  }
}
