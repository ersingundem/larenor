import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:larenor/features/fair_chores/data/fair_chore_controller.dart';
import 'package:larenor/features/fair_chores/domain/fair_chore_models.dart';
import 'package:larenor/features/fair_chores/presentation/fair_chore_screen.dart';

import 'fair_chore_controller_test.dart';

Future<void> pumpScreen(
  WidgetTester tester, {
  required Size size,
  required FairChoreStrings strings,
  required FakeFairChoreApi api,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final controller = FairChoreController(api, commandIds: () => 'ui-command');
  await tester.pumpWidget(
    MediaQuery(
      data: MediaQueryData(size: size, textScaler: const TextScaler.linear(2)),
      child: CupertinoApp(
        home: FairChoreScreen(
          controller: controller,
          authority: authorityA,
          strings: strings,
        ),
      ),
    ),
  );
  api.listRequests.single.complete(FairChorePage(authorityA, [task()]));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('EN and TR tablet widths keep 2x copy and 48dp actions usable', (
    tester,
  ) async {
    for (final sample in [
      (const Size(600, 900), FairChoreStrings.tr),
      (const Size(1200, 800), FairChoreStrings.en),
    ]) {
      final api = FakeFairChoreApi();
      await pumpScreen(tester, size: sample.$1, strings: sample.$2, api: api);
      expect(find.text(sample.$2.title), findsOneWidget);
      expect(find.text('Bitkileri sula'), findsOneWidget);
      expect(
        tester
            .getSize(find.byKey(const ValueKey('chore-complete-chore-1')))
            .height,
        greaterThanOrEqualTo(48),
      );
      expect(
        tester
            .getSize(find.byKey(const ValueKey('chore-defer-chore-1')))
            .height,
        greaterThanOrEqualTo(48),
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    }
  });

  testWidgets('TalkBack copy and keyboard completion invoke one real action', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final api = FakeFairChoreApi();
    await pumpScreen(
      tester,
      size: const Size(1200, 800),
      strings: FairChoreStrings.en,
      api: api,
    );
    expect(
      tester.getSemantics(find.byKey(const ValueKey('chore-complete-chore-1'))),
      matchesSemantics(
        label: 'Complete Bitkileri sula',
        isButton: true,
        hasEnabledState: true,
        isEnabled: true,
        hasTapAction: true,
      ),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(api.completeCalls, 1);
    semantics.dispose();
  });
}
